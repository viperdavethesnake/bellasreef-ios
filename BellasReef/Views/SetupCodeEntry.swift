// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

/// Feature 2 of the 2026-08-15 new-owner-experience spec: the screen a hub
/// in setup mode shows in place of the request-and-wait flow.
///
/// `/info` says `setup_mode` for exactly one moment in a hub's life — no
/// client has ever paired — and this is what lets the first device in on the
/// code printed at the end of `deploy-pi.sh`, with no SSH trip.
///
/// §7.1 states: idle, submitting, rejected, throttled. Rejection and
/// throttle both render fixed client copy rather than anything read off the
/// wire — controller ruling, 2026-08-15: the `/pair` 422 carries no typed
/// body in the 3.7.0 contract, so there is no server reason to show, and the
/// 429 body isn't parsed either.
struct SetupCodeEntry: View {
    let client: HubClient
    let onGranted: (String, String) async -> Void
    /// The "I don't have a code" fire escape's own race window: another
    /// device can finish pairing — via its own window, approval, or code —
    /// between this screen appearing and this submit landing, which both
    /// ends setup mode and makes a code-less `pair()` from here return a
    /// real 202 with a real approval code and a real expiry, exactly like
    /// the plain flow's own pending path. The caller lands this on the same
    /// `PendingApproval` screen the plain flow uses; this view has no
    /// waiting UI of its own to spend it on.
    let onPending: (HubClient.PendingPairing) async -> Void
    /// A 422 can mean the code was spent pairing a different device between
    /// this screen appearing and this submit landing. Re-fetching `/info`
    /// catches that: `setup_mode` flips false and the caller's `action(_:)`
    /// falls back to the normal request-and-wait branch on its own.
    let onSetupModeEnded: () async -> Void
    /// Anything outside the four states this screen owns — a Keychain that
    /// cannot hold a credential, a lost connection, an undocumented status.
    /// Handed to the caller's existing problem display rather than growing a
    /// fifth state here.
    let onError: (String) -> Void

    private enum FieldState: Equatable {
        case idle
        case submitting
        /// The code field's own submit came back wrong. §7.1 "rejected".
        case rejected
        /// The "I don't have a code" submit came back 422 — no window is
        /// open and a code has already been minted, so a code-less pair()
        /// no longer resolves via blind TOFU (review ruling, 2026-08-15,
        /// part (b)). Same visual slot as `.rejected`, different copy: this
        /// one is never about a wrong code, because no code was sent.
        case noCodeRejected
        case throttled
    }

    @State private var entry = ""
    @State private var clientName = DeviceName.suggested()
    @State private var state: FieldState = .idle

    private var canSubmit: Bool {
        entry.count == 8 && DeviceName.isUsable(clientName) && state != .submitting
    }

    /// The field shows `SetupCode.display`, grouped as you type; whatever
    /// comes back through `set` is normalized and capped at 8 — a ninth
    /// character can only be a typo, since every real code is exactly 8.
    private var displayBinding: Binding<String> {
        Binding(
            get: { SetupCode.display(entry) },
            set: { entry = String(SetupCode.normalize($0).prefix(8)) }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Enter the setup code")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("Enter the setup code from your deploy terminal.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)

            TextField("7KF2-9QMD", text: displayBinding)
                .font(.system(.title2, design: .monospaced))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .disabled(state == .submitting)
                .accessibilityIdentifier("setup-code-field")
                .padding(10)
                .background(Theme.surfaceRaised, in: .rect(cornerRadius: 8))
                // Editing the code retires whatever the last submit said —
                // "that code isn't right" surviving a fresh, uncommented
                // keystroke reads as a verdict on text nobody submitted yet.
                .onChange(of: entry) {
                    if state != .submitting { state = .idle }
                }

            nameField

            Button {
                Task { await submit() }
            } label: {
                if state == .submitting { ProgressView() } else { Text("Continue") }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(!canSubmit)

            switch state {
            case .rejected:
                Text("That code isn't right — it's on the deploy output; dashes and "
                     + "case don't matter.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
                    .multilineTextAlignment(.center)
            case .noCodeRejected:
                Text("No code and no open pairing window. On the hub, run "
                     + "`bellasreef setup-code` to print a fresh code.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
                    .multilineTextAlignment(.center)
            case .throttled:
                Text("Too many attempts — wait a minute.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
                    .multilineTextAlignment(.center)
            case .idle, .submitting:
                EmptyView()
            }

            // The fire escape for a lost or never-received code. Deliberately
            // plain and small next to `Continue` — this is the exceptional
            // path, not an equal alternative to typing the code (review
            // ruling, 2026-08-15, part (b)).
            Button("I don't have a code") {
                Task { await submitWithoutCode() }
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.secondaryText)
            .disabled(state == .submitting || !DeviceName.isUsable(clientName))
        }
        .frame(maxWidth: 320)
    }

    /// Mirrors `HubIdentifyCard.nameField` — the same reasoning applies: left
    /// to the system every device pairs as "iPhone", and this is what keeps
    /// the clients list legible months from now.
    @ViewBuilder
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This device is called")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
            TextField("Name this device", text: $clientName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .disabled(state == .submitting)
                .accessibilityIdentifier("client-name-field")
                .padding(10)
                .background(Theme.surfaceRaised, in: .rect(cornerRadius: 8))
        }
    }

    private func submit() async {
        state = .submitting
        let name = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch try await client.pair(clientName: name, setupCode: SetupCode.normalize(entry)) {
            case let .granted(refreshToken, clientId):
                await onGranted(refreshToken, clientId)
            case .codeRejected:
                state = .rejected
                await onSetupModeEnded()
            case .throttled:
                state = .throttled
            case .pending, .needsRecoveryCLI:
                // Unreachable per the 3.7.0 contract: a code-bearing pair()
                // call in setup mode is granted or 422, never queued or sent
                // to the fire escape.
                state = .idle
                onError("the hub returned an unexpected pairing outcome")
            }
        } catch {
            state = .idle
            onError("\(error)")
        }
    }

    /// The window-flow fire escape, reached from inside setup mode.
    ///
    /// A code-less `pair()` is not a shortcut around the code — it is the
    /// same call `bellasreef pair`'s window flow makes, and the hub resolves
    /// it the same way regardless of which screen sent it (review ruling,
    /// 2026-08-15, part (b)): an open recovery window grants immediately: an
    /// operator who opened one on the hub is not stuck behind a code they
    /// never received. With no window open, setup mode with no code ever
    /// minted still grants by blind TOFU — first client in, same as always.
    /// "A code exists and no window is open" comes back 422, read as "the
    /// code path is the only path right now" rather than as a wrong code,
    /// because this call sends none. And — the gap the 2026-08-15 round-2
    /// review caught — setup mode can end *between* this screen appearing
    /// and this submit landing (another device pairing by any path), which
    /// turns a code-less call into a genuine `.pending`: someone is now
    /// alive to approve, and the hub queues a real request with a real
    /// code. Every reachable outcome here has to leave a coherent state,
    /// not just the ones true at the moment the screen opened.
    private func submitWithoutCode() async {
        state = .submitting
        let name = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch try await client.pair(clientName: name) {
            case let .granted(refreshToken, clientId):
                await onGranted(refreshToken, clientId)
            case let .pending(pending):
                // Setup mode ended mid-screen; this is now a real approval
                // request. Hand it to the same landing the plain flow's
                // `.pending` uses, and refresh `/info` so `action(_:)` stops
                // routing back here on the next render.
                await onPending(pending)
                await onSetupModeEnded()
            case .needsRecoveryCLI:
                // Reachable only if setup mode ended AND every client that
                // caused it to end is now revoked — a narrow enough race
                // that there is nothing more specific to say than the
                // generic problem display.
                state = .idle
                onError("the hub returned an unexpected pairing outcome")
            case .codeRejected, .throttled:
                // Genuinely unreachable: both are only returned when this
                // call carries a `setupCode`, and this one never does.
                state = .idle
                onError("the hub returned an unexpected pairing outcome")
            }
        } catch HubClient.ClientError.throttled {
            // 429: distinct from `.rejected` precisely so this catch does
            // not have to inspect the reason string to tell a throttle
            // apart from a flat refusal (review ruling, 2026-08-15, round
            // 2: this used to fall into `.rejected` below and show the
            // wrong copy).
            state = .throttled
        } catch HubClient.ClientError.rejected {
            // Almost always the 422: no window open, and a code has already
            // been minted. `.rejected` also covers losing a 409 window race
            // against another device — the same copy still reads correctly
            // there ("no open window" became true the moment it lost), so
            // this does not need to split further, the same simplification
            // already made for `.codeRejected` above.
            state = .noCodeRejected
        } catch {
            state = .idle
            onError("\(error)")
        }
    }
}
