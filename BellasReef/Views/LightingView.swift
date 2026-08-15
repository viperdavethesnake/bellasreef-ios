// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

/// The Lighting tab: a real control surface for manual holds (spec Feature 2,
/// 2026-08-15). One card per adopted `light`-role actuator — the hub's own
/// reported duty, a proposed value, a duration, Hold, and (while a hold is
/// live) Release.
///
/// Reuses `TankView`'s data flow rather than opening a second stream
/// consumer: `model.monitor.channels` is the same frame dictionary the Tank
/// tab renders from, `model.catalog.devices` the same registry. This view
/// only adds the lighting-specific filter (`lightingCards`) and the command
/// path (`HubClient.hold`/`.release`) neither of Tank's read-only rows need.
struct LightingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if let monitor = model.monitor, let catalog = model.catalog {
                    content(monitor: monitor, catalog: catalog)
                } else {
                    ContentUnavailableView(
                        "Not connected",
                        systemImage: "wifi.slash",
                        description: Text("Reopen the app, or re-pair from the System tab.")
                    )
                }
            }
            .reefBackground()
            .navigationTitle("Lighting")
        }
    }

    @ViewBuilder
    private func content(monitor: TankMonitor, catalog: DeviceCatalog) -> some View {
        // Pure merge, same as `ActuatorSections` does for the Tank tab's
        // Equipment rows — the registry (what's adopted) and the stream
        // (what has actually reported) disagree by design, and `lightingCards`
        // is what reconciles them for this screen's filter (`role == "light"`).
        let cards = lightingCards(devices: catalog.devices, frames: monitor.channels)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if cards.isEmpty {
                    emptyState(loaded: catalog.state == .loaded)
                } else {
                    ForEach(cards) { card in
                        LightingCardView(card: card, client: model.client)
                    }
                    // One quiet footnote for the whole list (spec Feature 2)
                    // — the slider itself stays 0–100% unrestricted; this is
                    // what tells the operator why a 5% hold reads dark.
                    Text("Below 8% this dimmer is off.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Same pull-to-refresh contract as TankView: prove the socket is
        // real, then re-read the registry that doesn't push.
        .refreshable {
            await monitor.reconnect()
            await catalog.refresh()
        }
        .task { await catalog.refresh() }
        // The registry doesn't push — an adoption made on the System tab
        // while Lighting was backgrounded must not still read as "no lights"
        // on return.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await catalog.refresh() } }
        }
    }

    /// §7.1: loading and empty are distinct states, not one blank panel.
    /// Before the registry has loaded we do not yet know whether there is a
    /// light to show, so this stays tentative; once `catalog` confirms
    /// there truly is nothing adopted, the pinned copy says so plainly.
    @ViewBuilder
    private func emptyState(loaded: Bool) -> some View {
        Text(loaded ? "No lights adopted — adopt a PWM channel under System." : "Loading lights…")
            .font(Theme.caption)
            .foregroundStyle(loaded ? Theme.secondaryText : Theme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }
}

/// One light's card: truth line, active hold (if any), proposed slider,
/// duration, Hold, Release.
///
/// `@State` here is keyed to `card.id` by `ForEach` identity, so it survives
/// a re-render carrying a fresh frame (the slider does not jump under a
/// dragging thumb) but resets if the card itself disappears (a detached
/// light does not leave a ghost edit behind).
private struct LightingCardView: View {
    let card: LightingCard
    let client: HubClient?

    /// Percent, 0...100 — the *proposed* value. Seeded once from the hub's
    /// reported duty at first appearance and never re-synced from later
    /// frames: the truth line (`card.reportedDuty`/`card.hold`) is what
    /// renders hub state, and this must stay visibly the operator's own
    /// pending choice, not something the stream can silently overwrite out
    /// from under a drag in progress.
    @State private var proposedDuty: Double
    @State private var durationChoice: DurationChoice
    @State private var customMinutesText = ""
    /// Disables every control on this card while a Hold or Release is in
    /// flight (plan Task 2, Step 1).
    @State private var submitting = false
    @State private var problem: Problem?
    /// Toggled on a granted hold to fire the success haptic (design brief
    /// §7.4: "Overrides ... confirm with haptics").
    @State private var successPulse = 0

    private enum DurationChoice: Hashable {
        case preset(DurationPreset)
        case custom
    }

    private enum Problem: Equatable {
        /// 503 — pinned copy, not `HumanError` (plan Global Constraints).
        case clockUntrusted
        case message(String)

        var text: String {
            switch self {
            case .clockUntrusted:
                "The hub's clock is not trusted yet — holds need a deadline."
            case let .message(text):
                text
            }
        }
    }

    init(card: LightingCard, client: HubClient?) {
        self.card = card
        self.client = client
        _proposedDuty = State(initialValue: (card.reportedDuty ?? 0) * 100)
        let allowed = allowedDurations(maxRuntimeS: card.maxRuntimeS)
        _durationChoice = State(initialValue: allowed.first.map(DurationChoice.preset) ?? .custom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.name)
                    .font(Theme.sectionTitle)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                truthLine
            }

            if let hold = card.hold {
                HStack(alignment: .center) {
                    Label(
                        "Held at \(Int(hold.duty * 100))% · \(Self.remaining(hold.remainingS))",
                        systemImage: "hand.raised.fill"
                    )
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
                    Spacer()
                    // Not destructive (plan Global Constraints: Release
                    // returns the light to its resting state) — plain tap,
                    // no confirmation, no red.
                    Button("Release") { Task { await release(overrideId: hold.id) } }
                        .font(Theme.caption)
                        .buttonStyle(.borderless)
                        .disabled(submitting)
                        .accessibilityIdentifier("lighting-release-\(card.id)")
                }
                // 44pt minimum touch target on the row (§7.4), same idiom as
                // SystemView's Revoke row — the label text stays small.
                .frame(minHeight: 44)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Set to")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Text("\(Int(proposedDuty))%")
                        .font(Theme.value)
                        .foregroundStyle(Theme.accent)
                }
                Slider(value: $proposedDuty, in: 0...100, step: 1)
                    .disabled(submitting)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("lighting-slider-\(card.id)")
                    .accessibilityValue("\(Int(proposedDuty)) percent")
            }

            durationRow

            Button {
                Task { await hold() }
            } label: {
                if submitting { ProgressView() } else { Text("Hold") }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .disabled(submitting || durationS == nil || client == nil)
            .accessibilityIdentifier("lighting-hold-\(card.id)")

            if let problem {
                Label(problem.text, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            }
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.success, trigger: successPulse)
    }

    @ViewBuilder
    private var truthLine: some View {
        if let duty = card.reportedDuty {
            Text("\(Int(duty * 100))%")
                .font(Theme.value)
                .foregroundStyle(Theme.secondaryText)
        } else {
            // Mirrors `AdoptedSilentRow` (TankView): inventing 0% here would
            // claim a state the hub has not actually reported yet.
            Text("no state yet")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    @ViewBuilder
    private var durationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Duration", selection: $durationChoice) {
                ForEach(allowedDurations(maxRuntimeS: card.maxRuntimeS), id: \.self) { preset in
                    Text(Self.label(for: preset)).tag(DurationChoice.preset(preset))
                }
                Text("Custom").tag(DurationChoice.custom)
            }
            .pickerStyle(.menu)
            .disabled(submitting)
            .accessibilityIdentifier("lighting-duration-\(card.id)")

            if durationChoice == .custom {
                HStack {
                    Text("Minutes")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    TextField("Minutes", text: $customMinutesText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .disabled(submitting)
                        .frame(maxWidth: 80)
                        .accessibilityIdentifier("lighting-custom-minutes-\(card.id)")
                }
                if !customMinutesValid {
                    // §7.1 amber invalid state — guidance, not a destructive
                    // warning, same idiom as AdoptDeviceSheet's poll-interval hint.
                    Text(customMinutesHint)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.attention)
                }
            }
        }
    }

    // MARK: Duration math

    private var capMinutes: Int? { card.maxRuntimeS.map { Int($0 / 60) } }

    private var customMinutes: Int? {
        Int(customMinutesText.trimmingCharacters(in: .whitespaces))
    }

    private var customMinutesValid: Bool {
        guard let minutes = customMinutes, minutes >= 1 else { return false }
        if let cap = capMinutes, minutes > cap { return false }
        return true
    }

    private var customMinutesHint: String {
        if let cap = capMinutes { return "Enter 1–\(cap) minutes." }
        return "Enter at least 1 minute."
    }

    /// `nil` means "not a legal hold right now" — the Hold button reads this
    /// directly rather than duplicating the validation.
    private var durationS: Double? {
        switch durationChoice {
        case let .preset(preset): return preset.rawValue
        case .custom:
            guard customMinutesValid, let minutes = customMinutes else { return nil }
            return Double(minutes) * 60
        }
    }

    // MARK: Commands

    private func hold() async {
        guard let client, let durationS else { return }
        problem = nil
        submitting = true
        defer { submitting = false }
        do {
            switch try await client.hold(
                target: card.id, duty: proposedDuty / 100, durationS: durationS, reason: "manual"
            ) {
            case .granted:
                successPulse += 1
            case .notCommandable:
                problem = .message("This light is observe-only and can't be commanded from here.")
            case .clockUntrusted:
                problem = .clockUntrusted
            }
        } catch {
            problem = .message(HumanError.describe(error))
        }
    }

    private func release(overrideId: String) async {
        guard let client else { return }
        problem = nil
        submitting = true
        defer { submitting = false }
        do {
            // `.released`/`.alreadyReleased` both mean the hold is gone —
            // the next frame shows the light slewing back to its resting
            // state, same as any other target change (spec Feature 2).
            _ = try await client.release(overrideId: overrideId)
        } catch {
            problem = .message(HumanError.describe(error))
        }
    }

    // MARK: Copy

    private static func label(for preset: DurationPreset) -> String {
        switch preset {
        case .fifteenMinutes: "15 min"
        case .oneHour: "1 h"
        case .fourHours: "4 h"
        case .eightHours: "8 h"
        }
    }

    /// Same wording as `TankView.ChannelRow.remaining(_:)` — duplicated
    /// rather than shared, since that one is `private` to a file outside
    /// this task's scope (plan Task 2 touches only `LightingView.swift` and
    /// `RootView.swift`). Keep the two in sync if either changes.
    private static func remaining(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m left" }
        if minutes >= 1 { return "\(minutes)m left" }
        return "under a minute left"
    }
}
