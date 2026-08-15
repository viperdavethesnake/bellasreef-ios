// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Discovery → identify → pair, per auth.md §2.
struct PairingFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var discovery = HubDiscovery()
    @State private var manualAddress = ""
    @State private var selected: Hub?
    /// Drives the searching -> empty transition without a timer of its own.
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            List {
                // Why the app is here, when it did not arrive by being asked.
                // A pairing screen with no explanation reads as data loss.
                if let notice = model.notice {
                    Section {
                        Label {
                            Text(notice)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryText)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.attention)
                        }
                    }
                }

                Section("On this network") {
                    if discovery.hubs.isEmpty {
                        DiscoveryStatus(discovery: discovery, now: now)
                    }
                    ForEach(discovery.hubs) { hub in
                        Button { selected = hub } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hub.name).foregroundStyle(Theme.primaryText)
                                    Text(hub.baseURL.absoluteString)
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                    }
                }

                // Bonjour fails on guest networks, across VLANs, and over a
                // VPN. A controller you cannot reach because discovery is fussy
                // is not much of a controller.
                Section("By address") {
                    TextField("bellasreef.local or 192.168.1.20", text: $manualAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(connectManually)
                    Button("Connect", action: connectManually)
                        .disabled(Hub.manual(manualAddress) == nil)
                }
            }
            .scrollContentBackground(.hidden)
            .reefBackground()
            .navigationTitle("Find your hub")
            // Platform convention, and the manual recovery path. A browser
            // that has wedged is invisible from here, and the gesture people
            // already reach for is the one that fixes it.
            .refreshable { discovery.restart() }
            // A clock, so "searching" becomes "nothing here" without the model
            // owning a timer. Discovery publishes when results change; the
            // *absence* of results changes nothing, so nothing would redraw.
            .task(id: discovery.searchingSince) {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
            .onChange(of: scenePhase) { _, phase in
                // iOS tears network resources down in the background, often
                // without the browser ever reporting .failed — so nothing else
                // would notice it had stopped looking.
                if phase == .active { discovery.refreshOnForeground() }
            }
            .sheet(item: $selected) { hub in
                HubIdentifyCard(hub: hub)
            }
        }
    }

    /// The three §7.1 states this section can be in.
    ///
    /// Searching, empty and failed were one spinner before. An empty list and a
    /// dead browser looked identical, and only one of them means "type the
    /// address instead" — which is the whole reason the manual field exists.
    private struct DiscoveryStatus: View {
        let discovery: HubDiscovery
        let now: Date

        private var searchedFor: TimeInterval {
            guard let since = discovery.searchingSince else { return 0 }
            return now.timeIntervalSince(since)
        }

        var body: some View {
            switch discovery.state {
            case .failed:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Discovery is not running", systemImage: "wifi.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(Theme.attention)
                    // Named, not silent. The browser is retrying on its own, and
                    // an operator who does not know that will pull-to-refresh
                    // forever or conclude the hub is dead.
                    Text("The app could not search this network. Retrying — "
                         + "or enter the address below.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.vertical, 4)

            case .searching where searchedFor >= HubDiscovery.emptyStateAfter:
                VStack(alignment: .leading, spacing: 6) {
                    Text("No hub found on this network")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    // Bonjour genuinely does not work on guest networks, across
                    // VLANs, or over a VPN. After ten seconds the honest advice
                    // is to stop waiting.
                    Text("Bonjour does not cross guest networks, VLANs or a VPN. "
                         + "Enter the address below, or pull to search again.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.vertical, 4)

            case .searching, .idle:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(discovery.isBrowsing ? "Looking for your hub…" : "Starting…")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func connectManually() {
        guard let hub = Hub.manual(manualAddress) else { return }
        selected = hub
    }
}

/// `/info` before any commitment — the connect screen from auth.md step 2.
struct HubIdentifyCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let hub: Hub

    @State private var info: Components.Schemas.Info?
    @State private var problem: String?
    @State private var pairing = false
    @State private var pending: HubClient.PendingPairing?
    @State private var recoveryNeeded = false
    /// Built once, so the poller below talks to the same actor that pairs.
    @State private var client: HubClient?
    /// Editable, and seeded with something that is not "iPhone" — see
    /// `DeviceName`. This is the name the operator will have to recognise in a
    /// clients list months from now, when one of these devices is lost.
    @State private var clientName = DeviceName.suggested()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let info {
                    identity(info)
                    action(info)
                } else if let problem {
                    ContentUnavailableView(
                        "Cannot reach that hub",
                        systemImage: "wifi.exclamationmark",
                        description: Text(problem)
                    )
                } else {
                    ProgressView("Contacting hub…")
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
            .reefBackground()
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await identify() }
    }

    @ViewBuilder
    private func identity(_ info: Components.Schemas.Info) -> some View {
        VStack(spacing: 8) {
            Text(info.name).font(.title.weight(.semibold))
            Text(hub.baseURL.host ?? "").foregroundStyle(Theme.secondaryText)
            Text("API \(info.apiVersion) · contracts \(info.contractsVersion)")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private func action(_ info: Components.Schemas.Info) -> some View {
        if info.setupMode == true, let client {
            // Feature 2, 2026-08-15 new-owner-experience spec: a hub that
            // has never paired anyone shows the printed code instead of the
            // request-and-wait UI. `setup_mode` is false for every later
            // pair, so this branch never shadows the flow below it.
            SetupCodeEntry(
                client: client,
                onGranted: { refreshToken, clientId in
                    await complete(refreshToken: refreshToken, clientId: clientId, using: client)
                },
                // A race, not a hypothetical: another device can finish
                // pairing — via its own window, approval, or code — while
                // this screen is open, which both ends setup mode and makes
                // a code-less pair() from here return a real 202 with a
                // real code and a real expiry. Lands in the same
                // `PendingApproval` the plain flow uses; `refreshInfo()`
                // moves `info.setupMode` off stale so `action(_:)` actually
                // falls through to the `pending` branch below on the next
                // render instead of re-showing this one.
                onPending: { newPending in
                    self.pending = newPending
                    await refreshInfo()
                },
                onSetupModeEnded: { await refreshInfo() },
                onError: { problem = $0 }
            )
        } else if recoveryNeeded {
            // Verbatim from auth.md: the operator needs the exact command, and
            // paraphrasing a recovery instruction is how people end up stuck.
            VStack(spacing: 12) {
                Label("Nobody can approve this device", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.attention)
                Text("run `bellasreef pair` on the hub")
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .background(Theme.surfaceRaised, in: .rect(cornerRadius: 8))
                Text("Every paired device has been revoked, so there is no one to "
                     + "approve a new one. Open a recovery window on the hub, then "
                     + "try again.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        } else if let pending, let client {
            PendingApproval(
                pending: pending,
                client: client,
                onGranted: { refreshToken, clientId in
                    await complete(refreshToken: refreshToken, clientId: clientId, using: client)
                },
                onStartOver: { self.pending = nil }
            )
        } else {
            VStack(spacing: 14) {
                Text(prospect(info))
                    .font(.callout)
                    .foregroundStyle(info.approversAvailable == false && info.pairingOpen == false
                                     ? Theme.attention : Theme.secondaryText)
                    .multilineTextAlignment(.center)

                nameField

                Button {
                    Task { await pair() }
                } label: {
                    if pairing { ProgressView() } else { Text("Pair this device") }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(pairing || !DeviceName.isUsable(clientName))
            }
        }

        if let problem {
            Text(problem)
                .font(Theme.caption)
                .foregroundStyle(Theme.attention)
                .multilineTextAlignment(.center)
        }
    }

    /// The name the hub will file this device under.
    ///
    /// A field rather than `UIDevice.current.name`, which returns the model on
    /// iOS 16+ without an entitlement this project does not declare. Left to the
    /// system, every device pairs as "iPhone" and the clients list is a column
    /// of identical rows next to identical Revoke buttons.
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
                .accessibilityIdentifier("client-name-field")
                .padding(10)
                .background(Theme.surfaceRaised, in: .rect(cornerRadius: 8))
            Text("You will look for this name when revoking a lost device.")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: 320)
    }

    /// What will actually happen if this button is pressed.
    ///
    /// Three states, not two. `pairing_open` is keyed on clients *ever* paired,
    /// so it stays false forever once anything has paired — including after
    /// every client is revoked. Reading only that flag produced "an
    /// already-paired device will need to approve this one" on a hub where no
    /// such device existed, and no amount of waiting would have helped.
    private func prospect(_ info: Components.Schemas.Info) -> String {
        if info.pairingOpen == true {
            return "This hub has never been paired. The first device in is trusted."
        }
        if info.approversAvailable == true {
            return "This device will show a six-digit code. Type it into a device that is "
                + "already paired, under System → Add a device."
        }
        return "No paired device is left to approve this one. "
            + "Open a pairing window on the hub first."
    }

    private func identify() async {
        let client = HubClient(hub: hub)
        self.client = client
        do {
            info = try await client.info()
        } catch {
            problem = "\(error)"
        }
    }

    /// Re-checks `/info` on the existing client, without discarding it.
    ///
    /// `SetupCodeEntry` calls this after a rejected setup code: the code may
    /// have paired a different device in the meantime, which flips
    /// `setup_mode` false and sends `action(_:)` back to the normal
    /// request-and-wait branch on its own. A failure here is silent by
    /// design — the setup-code screen is still showing its own rejection
    /// copy, and there is nothing more useful to say about a background
    /// re-check that did not land.
    private func refreshInfo() async {
        guard let client else { return }
        if let fresh = try? await client.info() {
            info = fresh
        }
    }

    private func pair() async {
        pairing = true
        defer { pairing = false }
        problem = nil

        guard let client else { return }
        do {
            switch try await client.pair(clientName: clientName.trimmingCharacters(in: .whitespacesAndNewlines)) {
            case let .granted(refreshToken, clientId):
                await complete(refreshToken: refreshToken, clientId: clientId, using: client)
            case let .pending(pending):
                self.pending = pending
            case .needsRecoveryCLI:
                recoveryNeeded = true
            case .codeRejected, .throttled:
                // Unreachable here: this call never sends a setupCode, and
                // the hub only returns these two in response to one.
                // Handled so the switch stays exhaustive as the outcome
                // enum grows for SetupCodeEntry's use.
                problem = "unexpected pairing response"
            }
        } catch {
            problem = "\(error)"
        }
    }

    /// Store the credential and go. The one step that must not fail quietly.
    ///
    /// By here the hub has already spent whatever it had to spend, which is why
    /// `pair()` probes the Keychain first. If the write still fails, the error
    /// is reported as itself rather than as a generic "something went wrong" —
    /// the operator is about to need SSH and deserves to know which failure
    /// sent them there.
    private func complete(refreshToken: String, clientId: String, using client: HubClient) async {
        do {
            try await client.store(refreshToken: refreshToken)
        } catch {
            problem = "The hub issued a credential and this device could not store it: "
                + "\(error). The credential is gone; run `bellasreef pair` on the hub to "
                + "open another window."
            // Off the waiting screen, so the sentence above is readable and the
            // spinner does not imply something is still in progress. Nothing is.
            pending = nil
            return
        }
        HubMemory.remember(hub, clientId: clientId)
        model.adopt(client, hub: hub)
        dismiss()
    }
}

/// The 202 path: show the code, and poll until the hub says something.
///
/// This screen was a `ProgressView` and three labels — no `.task`, no timer, no
/// request. Approval on the hub side worked and was tested; the waiting device
/// simply never came back to collect, so the spinner ran until the operator gave
/// up. Every branch below is reachable for the first time.
struct PendingApproval: View {
    let pending: HubClient.PendingPairing
    let client: HubClient
    let onGranted: (String, String) async -> Void
    let onStartOver: () -> Void

    /// What the hub last said. Five endings, five sets of words, five ways out.
    private enum Outcome: Equatable {
        case waiting
        case granted
        /// 403
        case denied
        /// 404
        case unknown
        /// 410 — expired, or the credential was already collected.
        case gone
    }

    @State private var outcome: Outcome = .waiting
    /// Ticks so the countdown moves. The deadline is fixed at init; only `now`
    /// changes, so the number cannot drift the way a decrementing counter does.
    @State private var now = Date()
    /// A network blip while polling. Not an ending — the request is still
    /// pending on the hub, and saying "failed" would be a lie the operator acts
    /// on.
    @State private var glitch: String?

    /// @State, not a stored let: a plain let is recomputed by every
    /// re-initialization of this struct, while the long-lived task closures
    /// below keep the copy they captured — the rendered countdown and the
    /// expiry logic would then disagree. State survives re-init, so both read
    /// the date fixed when the screen first appeared.
    @State private var deadline: Date

    init(
        pending: HubClient.PendingPairing,
        client: HubClient,
        onGranted: @escaping (String, String) async -> Void,
        onStartOver: @escaping () -> Void
    ) {
        self.pending = pending
        self.client = client
        self.onGranted = onGranted
        self.onStartOver = onStartOver
        _deadline = State(initialValue: Date().addingTimeInterval(TimeInterval(pending.expiresIn)))
    }

    private var remaining: Int { max(0, Int(deadline.timeIntervalSince(now).rounded())) }

    var body: some View {
        VStack(spacing: 16) {
            switch outcome {
            case .waiting: waiting
            case .granted:
                ProgressView("Approved — finishing up…")
            case .denied:
                ending(
                    "That request was denied",
                    icon: "hand.raised.fill",
                    detail: "Someone declined it on the hub. Nothing was stored on this device."
                )
            case .unknown:
                ending(
                    "The hub has no record of that request",
                    icon: "questionmark.circle.fill",
                    detail: "It was swept after expiring, or the hub restarted. Start again "
                          + "to get a fresh code."
                )
            case .gone:
                ending(
                    "That code is no longer usable",
                    icon: "clock.badge.xmark.fill",
                    detail: "A request lasts a few minutes, and its credential can be "
                          + "collected exactly once. Start again to get a fresh code."
                )
            }
        }
        .padding(.horizontal, 24)
        // The poll, on the cadence the 202 body already told us.
        .task {
            let cadence = max(1, pending.pollAfter)
            while outcome == .waiting && !Task.isCancelled {
                do {
                    let answer = try await client.poll(requestId: pending.requestId)
                    // The clock task below can settle the outcome (via its own
                    // final poll at expiry) while this request was in flight;
                    // an answer to a question that has been settled is dropped.
                    guard outcome == .waiting else { return }
                    switch answer {
                    case let .granted(refreshToken, clientId):
                        outcome = .granted
                        await onGranted(refreshToken, clientId)
                        return
                    case .stillPending:
                        glitch = nil
                    case .denied:
                        outcome = .denied
                        return
                    case .unknown:
                        outcome = .unknown
                        return
                    case .gone:
                        outcome = .gone
                        return
                    }
                } catch {
                    // Keep polling. The request is alive on the hub whether or
                    // not this device can reach it right now, and the countdown
                    // below is what ends the wait if it never can.
                    glitch = "\(error)"
                }
                try? await Task.sleep(for: .seconds(cadence))
            }
        }
        // A clock, so the expiry is a number that moves rather than a sentence
        // that was hardcoded to five minutes while the real figure arrived in
        // the 202 body and was discarded.
        .task {
            while !Task.isCancelled {
                now = Date()
                if remaining == 0 && outcome == .waiting {
                    // Local expiry is this device's guess, and the app may have
                    // been suspended past the deadline while the approver typed
                    // the code — both continuations then resume in arbitrary
                    // order. One final poll before declaring the ending: an
                    // approved credential is collectible until the hub itself
                    // says otherwise, and "start again" over a granted approval
                    // both strands the operator and spends the grant.
                    let answer = try? await client.poll(requestId: pending.requestId)
                    guard outcome == .waiting else { return }
                    switch answer {
                    case let .granted(refreshToken, clientId):
                        outcome = .granted
                        await onGranted(refreshToken, clientId)
                    case .denied: outcome = .denied
                    case .unknown: outcome = .unknown
                    case .gone, .stillPending, nil: outcome = .gone
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var waiting: some View {
        Label("Approve this device", systemImage: "person.badge.key")
            .font(.headline)
            .foregroundStyle(Theme.attention)

        Text(grouped(pending.pairingCode))
            .font(.system(size: 44, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.primaryText)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(Theme.surfaceRaised, in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("pairing-code")
            // VoiceOver reads "482913" as four hundred and eighty-two thousand.
            // Digits are what the operator has to type.
            .accessibilityLabel(
                "Pairing code, " + pending.pairingCode.map(String.init).joined(separator: " ")
            )

        Text("On a device that is already paired, open System → Add a device and "
             + "type these six digits.")
            .font(.callout)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)

        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(remaining > 0 ? "Expires in \(clock(remaining))" : "Expired")
                .font(Theme.caption)
                .monospacedDigit()
                .foregroundStyle(remaining > 30 ? Theme.tertiaryText : Theme.attention)
        }

        if let glitch {
            Text("Cannot reach the hub — still trying. (\(glitch))")
                .font(Theme.caption)
                .foregroundStyle(Theme.attention)
                .multilineTextAlignment(.center)
        }

        Button("Cancel and start over", role: .cancel, action: onStartOver)
            .frame(minHeight: 44)
    }

    @ViewBuilder
    private func ending(_ title: String, icon: String, detail: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(Theme.attention)
        Text(detail)
            .font(.callout)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
        Button("Start over", action: onStartOver)
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
    }

    /// "482 913" — six digits are easier to read across a room in two groups.
    private func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
