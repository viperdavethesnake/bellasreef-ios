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
                if let monitor = model.monitor, let catalog = model.catalog, let library = model.library {
                    content(monitor: monitor, catalog: catalog, library: library)
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
            // Inline titles blurred over content that scrolled under them (UX
            // review B2). The soft edge effect is the system's answer.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbar {
                NavigationLink {
                    SchedulesView()
                } label: {
                    Label("Schedules", systemImage: "calendar.badge.clock")
                }
                .accessibilityIdentifier("lighting-schedules")
            }
        }
    }

    @ViewBuilder
    private func content(monitor: TankMonitor, catalog: DeviceCatalog, library: ScheduleLibrary) -> some View {
        // Pure merge, same as `ActuatorSections` does for the Tank tab's
        // Equipment rows — the registry (what's adopted) and the stream
        // (what has actually reported) disagree by design, and `lightingCards`
        // is what reconciles them for this screen's filter (`role == "light"`).
        let cards = lightingCards(
            devices: catalog.devices, frames: monitor.channels, schedules: library.schedules
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // A control surface showing a last-known duty with no
                // connection indication is dishonest (review, 2026-08-15) —
                // but the sensor-aware line leaked "Waiting for a sensor"
                // into a tab about lights (rehearsal F4). Connection-scoped:
                // the socket's honesty and the interlock, nothing sensor.
                StatusLine(monitor: monitor, scope: .connection)

                if cards.isEmpty {
                    emptyState(catalog: catalog)
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
                    // Hoisted from per-card to once-per-list (final review,
                    // 2026-08-17) — the two-sentence snap/ramp explanation
                    // was repeating under every card's Hold row; it says the
                    // same thing regardless of which light it sits under.
                    Text("Snap goes to the level at once and leaves it at once. Ramp fades at the hub's rate, both ways.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // By id, not by card value: the destination re-resolves the card
        // live, so a frame arriving while the detail is up updates it.
        .navigationDestination(for: String.self) { id in
            LightDetailView(cardId: id)
        }
        // Same pull-to-refresh contract as TankView: prove the socket is
        // real, then re-read the registry that doesn't push.
        .refreshable {
            await monitor.reconnect()
            await catalog.refresh()
            await library.refresh()
        }
        .task {
            await catalog.refresh()
            await library.refresh()
        }
        // The registry doesn't push — an adoption made on the System tab
        // while Lighting was backgrounded must not still read as "no lights"
        // on return. The same is true of a schedule assignment made on the
        // Schedules tab.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await catalog.refresh()
                    await library.refresh()
                }
            }
        }
    }

    /// §7.1/§7.2: loading, confirmed-empty and failed are three different
    /// states, not one collapsed to a bool (review, 2026-08-15 — a `.failed`
    /// catalog used to render as an eternal "Loading lights…", which is
    /// exactly the "spinner-forever" §7.1 rules out).
    @ViewBuilder
    private func emptyState(catalog: DeviceCatalog) -> some View {
        switch catalog.state {
        case .idle, .loading:
            Text("Loading lights…")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
        case .loaded:
            Text("No lights adopted — adopt a PWM channel under System.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
        case let .failed(message):
            // Same idiom as `HistoryView.Failure`/`AuditLogView`'s retry
            // state — amber, with a retry affordance — restated here rather
            // than reused because those views' copy is hardcoded to their
            // own tab ("Could not load history").
            VStack(alignment: .leading, spacing: 10) {
                Label("Could not load the device registry", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.attention)
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                Button("Try again") { Task { await catalog.refresh() } }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
        }
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
    /// reported duty at first appearance, and re-seeded from later frames
    /// only until the operator touches the slider (`draftTouched`, below):
    /// before that touch it is a convenience tracking the hub, not a
    /// proposal, so a schedule moving underneath it must not leave the
    /// caption nagging about a choice nobody made (UX review SF9). Once
    /// touched, the truth line (`card.reportedDuty`/`currentHold()`) is what
    /// renders hub state and this stays visibly the operator's own pending
    /// choice, not something the stream can silently overwrite out from
    /// under a drag in progress.
    @State private var proposedDuty: Double
    /// Gates the re-seed above: false until the operator drags the slider,
    /// reset back to false whenever the draft is abandoned (`.onDisappear`)
    /// or committed (a successful hold) — both are moments a fresh seed from
    /// the hub is correct again, not a stream overwrite in progress.
    @State private var draftTouched = false
    @State private var durationChoice: DurationChoice
    @State private var customMinutesText: String
    /// The operator's snap-vs-ramp choice, remembered across cards and
    /// launches (`@AppStorage`, spec 2026-08-17). First-run default is
    /// snap — the complaint that started this was a hold taking ~100 s to
    /// arrive. Stored as the wire string so a stale value can never decode
    /// to something the hub would reject; anything unreadable falls back to
    /// snap.
    @AppStorage("lighting.holdTransition") private var transitionRaw: String = HubClient.HoldTransition.snap.rawValue

    private var transition: HubClient.HoldTransition {
        get { HubClient.HoldTransition(rawValue: transitionRaw) ?? .snap }
        nonmutating set { transitionRaw = newValue.rawValue }
    }
    /// Disables every control on this card while a Hold or Release is in
    /// flight (plan Task 2, Step 1).
    @State private var submitting = false
    @State private var problem: Problem?
    /// Toggled on a granted hold to fire the success haptic (design brief
    /// §7.4: "Overrides ... confirm with haptics").
    @State private var successPulse = 0
    /// Bumped on every Hold tap for the `.selection` haptic (UX review B8).
    @State private var holdTapped = 0

    /// A Hold's own grant response, shown immediately rather than waiting on
    /// the next state frame (review, 2026-08-15: `HoldOutcome.granted`
    /// carries the whole created override for exactly this). Cleared once a
    /// frame speaks for this device at all (`onChange(of: card.hold)`,
    /// below) and, independently, treated as absent by `effectiveHold` once
    /// its own `expiresAt` passes — a round-2 review fix (C1): without the
    /// expiry check, a hold that expires on the hub while the stream stays
    /// quiet would render as a live "under a minute left" forever, since
    /// nothing was left to ever clear it.
    @State private var optimisticHold: LightingCard.ActiveHold?
    /// Override ids `effectiveHold` (kit) must treat as stale regardless of
    /// what the frame or the optimistic copy still say. Two distinct
    /// sources feed this, both round-2 review fixes:
    /// - `release(overrideId:)` inserts an id this client just released, so
    ///   a frame that lags the release by one beat can't make an
    ///   already-released hold look re-releasable ("second tap isn't
    ///   silently possible") — C1.
    /// - `hold()` seeds this with whatever hold the frame currently shows
    ///   *before* a fresh grant, because a same-duty re-hold supersedes on
    ///   the backend but the engine's deadband can leave the old hold in
    ///   the next several frames with nothing new to publish — I1.
    @State private var releasedIDs: Set<String> = []
    /// The hold pending confirmation, if the operator has tapped Release —
    /// §7.4's standard destructive-confirm pattern (review, 2026-08-15:
    /// ruled that §7.4 governs here, over this file's earlier no-confirm
    /// reading of the plan). Holding the value itself, not just a `Bool`,
    /// mirrors `SystemView`'s `revoking`/`forgetting`/`unadopting` —
    /// `confirmationDialog(presenting:)` needs the row it will act on.
    @State private var confirmingRelease: LightingCard.ActiveHold?

    private enum DurationChoice: Hashable {
        case preset(DurationPreset)
        case custom
    }

    private enum Problem: Equatable {
        /// 503 — pinned copy, not `HumanError` (plan Global Constraints).
        /// The sentence itself now lives in `HoldRefusal` (kit), because the
        /// Hold app intent answers the same refusal and must say the same
        /// thing (UX review D3).
        case clockUntrusted
        case message(String)

        var text: String {
            switch self {
            case .clockUntrusted:
                HoldRefusal.clockUntrusted.message
            case let .message(text):
                text
            }
        }
    }

    init(card: LightingCard, client: HubClient?) {
        self.card = card
        self.client = client
        _proposedDuty = State(initialValue: ((card.reportedDuty ?? 0) * 100).rounded())
        let allowed = allowedDurations(maxRuntimeS: card.maxRuntimeS)
        _durationChoice = State(initialValue: allowed.first.map(DurationChoice.preset) ?? .custom)
        // Seeded valid rather than empty (review fold, 2026-08-15, mirroring
        // AdoptDeviceSheet's poll-interval default): an empty field read as
        // invalid before the operator had touched anything, so the amber
        // hint appeared on a card nobody had edited yet.
        _customMinutesText = State(
            initialValue: String(min(holdMinutesCap(maxRuntimeS: card.maxRuntimeS), 60))
        )
    }

    /// This card's own call into the pure `effectiveHold(...)` precedence
    /// function (kit) — `now` defaults to the call-time instant for the
    /// non-ticking uses (the accessibility label); the visible countdown
    /// passes a `TimelineView`'s tick instead, below, which is what lets an
    /// expired optimistic hold clear itself without waiting on a new frame
    /// or any other `@State` change (review round 2, 2026-08-15 — C1).
    private func currentHold(now: Date = Date()) -> LightingCard.ActiveHold? {
        effectiveHold(
            frameHold: card.hold, optimisticHold: optimisticHold, releasedIDs: releasedIDs, now: now
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                NavigationLink(value: card.id) {
                    HStack(spacing: 4) {
                        Text(card.name)
                            .font(Theme.sectionTitle)
                            .foregroundStyle(Theme.primaryText)
                        Image(systemName: "chevron.right")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lighting-detail-\(card.id)")
                Spacer()
                truthLine
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(truthAccessibilityLabel)
            // `.combine` unions its children's traits into the merged
            // element and forwards the sole actionable child's activation —
            // here, the `NavigationLink`'s. Declared explicitly rather than
            // left implicit: a reviewer (or a future edit) reading this file
            // should not have to trust undocumented-at-a-glance combine
            // behavior to know the row still announces and activates as a
            // button for VoiceOver.
            .accessibilityAddTraits(.isButton)

            if let schedule = card.schedule {
                // The caption reuses this TimelineView's own `context.date`
                // rather than a fresh `Date()` (SF3) — the mini curve above
                // already ticks every 30s, so the target duty it compares
                // against and the dot it draws never disagree about "now".
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        MiniDayCurve(
                            curve: schedule.curve,
                            nowSeconds: schedule.curve.secondsOfDay(for: context.date),
                            nowDuty: card.reportedDuty
                        )
                        Text(schedule.name)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText)
                        // Only when no hold is active (spec SF3) — a hold's
                        // duty is a deliberate override, not the engine
                        // "catching up," so the caption would be misleading
                        // while one is live.
                        if currentHold(now: context.date) == nil, let caption = Dimming.convergenceCaption(
                            reportedDuty: card.reportedDuty,
                            targetDuty: schedule.curve.duty(at: context.date)
                        ) {
                            Text(caption)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            } else {
                // Absence is a state, not a blank: with nothing assigned the
                // engine rests this channel dark (composition law — resting
                // is the schedule's value, else SAFE_DUTY).
                Text("No schedule — resting is off.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }

            // The TimelineView wraps the *presence* decision, not just the
            // countdown text (review round 2, 2026-08-15 — C1): an
            // optimistic hold that outlives its own `expiresAt` with no
            // fresher frame ever arriving (a quiet stream at exactly the
            // wrong moment) must stop rendering once real time passes it,
            // and nothing but a live clock tick can notice that on its own
            // — no `@State` changes when nothing else happens.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                if let hold = currentHold(now: context.date) {
                    HStack(alignment: .center) {
                        Label(
                            "Held at \(Dimming.percent(hold.duty))% · \(hold.transition.label) · "
                                + "\(formatRemaining(secondsRemaining(hold, now: context.date)))"
                                + returnsToText(hold),
                            systemImage: "hand.raised.fill"
                        )
                        .font(Theme.caption)
                        .foregroundStyle(Theme.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Release") { confirmingRelease = hold }
                            .font(Theme.caption)
                            .buttonStyle(.borderless)
                            .disabled(submitting)
                            .accessibilityIdentifier("lighting-release-\(card.id)")
                    }
                    // 44pt minimum touch target on the row (§7.4), same
                    // idiom as SystemView's Revoke row — the label text
                    // stays small.
                    .frame(minHeight: 44)
                }
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
                // Snap on release, not while dragging: the thumb should go
                // where the finger is, and then land where the hub would put
                // it (UX review A6). The value the operator sees is the value
                // the pin gets.
                Slider(value: $proposedDuty, in: 0...100, step: 1) { editing in
                    if editing { draftTouched = true }
                    if !editing { proposedDuty = Dimming.snapPercent(proposedDuty) }
                }
                    .disabled(submitting)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("lighting-slider-\(card.id)")
                    .accessibilityLabel("\(card.name), proposed duty")
                    .accessibilityValue("\(Int(proposedDuty)) percent")
                // A proposal is a pending choice, not a state report (UX review
                // A4). Say so whenever it differs from what the hub reports;
                // say what will happen when it sits under the floor.
                if let caption = Dimming.proposalCaption(
                    proposedPercent: proposedDuty, reportedDuty: card.reportedDuty
                ) {
                    Text(caption)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("lighting-proposal-caption-\(card.id)")
                }
            }

            durationRow

            HStack(spacing: 12) {
                Picker("Transition", selection: Binding(
                    get: { transition }, set: { transition = $0 }
                )) {
                    Text("Snap").tag(HubClient.HoldTransition.snap)
                    Text("Ramp").tag(HubClient.HoldTransition.ramp)
                }
                .pickerStyle(.segmented)
                .disabled(submitting)
                .frame(maxWidth: 160)
                .accessibilityIdentifier("lighting-transition-\(card.id)")

                Button {
                    holdTapped += 1
                    Task { await hold() }
                } label: {
                    if submitting { ProgressView() } else { Text("Hold") }
                }
                .buttonStyle(.borderedProminent)
                // The tap itself is acknowledged (UX review B8); `.success` on
                // the grant stays separate, below.
                .sensoryFeedback(.selection, trigger: holdTapped)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .disabled(submitting || durationS == nil || client == nil)
                .accessibilityIdentifier("lighting-hold-\(card.id)")
            }

            if let problem {
                Label(problem.text, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            }
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        // A draft nobody committed is not state worth keeping across a tab
        // switch: on return the slider sits at what the hub reports, so the
        // card reads as a report again (UX review A4). Resetting
        // `draftTouched` here is what lets the `onChange` below keep tracking
        // the hub on the next appearance, same as a fresh card would.
        .onDisappear {
            if !submitting {
                proposedDuty = ((card.reportedDuty ?? 0) * 100).rounded()
                draftTouched = false
            }
        }
        // The seed is a convenience, not a proposal: until the operator
        // touches the slider, it tracks the hub so the caption cannot nag
        // about a choice nobody made (UX review 2026-08-23, SF9 — the
        // schedule moved and the app said "Set to 82% · not applied yet").
        .onChange(of: card.reportedDuty) {
            if !draftTouched && !submitting {
                proposedDuty = ((card.reportedDuty ?? 0) * 100).rounded()
            }
        }
        .sensoryFeedback(.success, trigger: successPulse)
        // A problem sticks around only until the operator changes something
        // — a stale rejection sitting under a fresh edit or a hold that has
        // since changed shape reads as though the *new* state is what
        // failed (review fold, 2026-08-15).
        .onChange(of: proposedDuty) { problem = nil }
        .onChange(of: durationChoice) { problem = nil }
        .onChange(of: customMinutesText) { problem = nil }
        .onChange(of: card.hold) { _, newValue in
            problem = nil
            // Retire the optimistic copy the moment a frame speaks for this
            // device at all (review round 2, 2026-08-15 — C1): once the
            // frame has an account, `effectiveHold` prefers it regardless,
            // so this is belt-and-braces against the stale optimistic value
            // surviving to be wrongly consulted later, after the frame goes
            // quiet again for real (the hold's natural expiry).
            if newValue != nil { optimisticHold = nil }
            // Keep the Lock Screen banner on the hub's own account of this
            // hold — the level it reports may differ from the one that was
            // asked for (the 8 % floor snaps down). Matched by override id
            // inside the controller, so a frame describing a *different*
            // hold updates nothing; that case is a supersede, and `hold()`
            // starts a fresh activity for it.
            if let newValue {
                Task { await HoldActivityController.shared.update(hold: newValue) }
            }
        }
        // §7.4 standard destructive-confirm pattern, the same shape
        // SystemView uses for Revoke/Unadopt/Clear (ruled 2026-08-15: this
        // wins over this file's earlier no-confirm reading — control-red
        // here is the platform's "this deletes something," not the safety
        // red that governs status and interlocks, so the color concern that
        // motivated skipping confirmation doesn't apply).
        .confirmationDialog(
            "Release this hold?",
            isPresented: Binding(
                get: { confirmingRelease != nil },
                set: { if !$0 { confirmingRelease = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingRelease
        ) { hold in
            Button("Release \(card.name)", role: .destructive) {
                Task { await release(overrideId: hold.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The light returns to its resting state.")
        }
    }

    private func secondsRemaining(_ hold: LightingCard.ActiveHold, now: Date) -> Double {
        max(0, hold.expiresAt.timeIntervalSince(now))
    }

    /// What release/expiry goes back to — computable now that resting has a
    /// value (spec 2026-08-19: "returns to N %" from the curve at expiry).
    /// Silent with no schedule: "returns to off" is already what the layout
    /// says one line up, and repeating it in every hold row is noise.
    private func returnsToText(_ hold: LightingCard.ActiveHold) -> String {
        guard let schedule = card.schedule else { return "" }
        let duty = schedule.curve.duty(at: hold.expiresAt)
        return " · returns to \(Int((duty * 100).rounded()))%"
    }

    @ViewBuilder
    private var truthLine: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // A one-word caption so truth vs. proposed isn't color-only
            // (review fold, 2026-08-15) — pairs with "Set to" below.
            Text("Now")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
            if let duty = card.reportedDuty {
                Text("\(Dimming.percent(duty))%")
                    .font(Theme.value)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                // Mirrors `AdoptedSilentRow` (TankView): inventing 0% here
                // would claim a state the hub has not actually reported yet.
                Text("no state yet")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    /// Composed sentence, `TankView.ChannelRow.spoken(...)`'s pattern: name,
    /// then duty (or its absence), then hold state, joined as one utterance
    /// rather than three separately-focused elements.
    private var truthAccessibilityLabel: String {
        var parts = [card.name]
        parts.append(card.reportedDuty.map { "\(Dimming.percent($0)) percent" } ?? "no state yet")
        if let hold = currentHold() {
            parts.append(
                "held at \(Dimming.percent(hold.duty)) percent, \(hold.transition.label.lowercased()) transition"
            )
        }
        return parts.joined(separator: ", ")
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
                    // Reachable only once the operator has edited away from
                    // the seeded valid default, above.
                    Text(customMinutesHint)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.attention)
                }
            }
        }
    }

    // MARK: Duration math

    /// The kit's one cap rule, shared with the Hold app intent (UX review D3)
    /// — this used to be `max_runtime_s / 60` and nothing else, which let a
    /// card with no declared runtime offer a duration the hub's own spec
    /// refuses. `holdMinutesCap` folds both ceilings together and always has
    /// one, so this is no longer optional.
    private var capMinutes: Int { holdMinutesCap(maxRuntimeS: card.maxRuntimeS) }

    private var customMinutes: Int? {
        Int(customMinutesText.trimmingCharacters(in: .whitespaces))
    }

    private var customMinutesValid: Bool {
        guard let minutes = customMinutes else { return false }
        return IntentSupport.durationS(minutes: minutes, maxRuntimeS: card.maxRuntimeS) != nil
    }

    private var customMinutesHint: String { "Enter 1–\(capMinutes) minutes." }

    /// `nil` means "not a legal hold right now" — the Hold button reads this
    /// directly rather than duplicating the validation.
    private var durationS: Double? {
        switch durationChoice {
        case let .preset(preset): return preset.rawValue
        case .custom:
            guard let minutes = customMinutes else { return nil }
            return IntentSupport.durationS(minutes: minutes, maxRuntimeS: card.maxRuntimeS)
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
                target: card.id, duty: proposedDuty / 100, durationS: durationS, reason: "manual",
                transition: transition
            ) {
            case let .granted(overrideView):
                // Show this grant now, not on the next frame (review,
                // 2026-08-15) — `effectiveHold` prefers `card.hold` the
                // moment the frame catches up, so this is only ever the
                // gap-filler.
                let granted = LightingCard.ActiveHold(
                    id: overrideView.id, duty: overrideView.duty, expiresAt: overrideView.expiresAt,
                    transition: HubClient.HoldTransition(overrideView.transition)
                )
                optimisticHold = granted
                // The same grant, on the Lock Screen (UX review D2). Started
                // from the grant rather than the next frame for the same
                // reason the card shows it optimistically: the banner should
                // be there when the operator looks up from the tap.
                await HoldActivityController.shared.start(hold: granted, light: card)
                // Seed `releasedIDs` with whatever hold the frame currently
                // shows, rather than clearing it (review round 2, 2026-08-15
                // — I1): a re-hold at the SAME duty is a supersede on the
                // backend, but the engine's deadband can mean no new frame
                // is ever published to reflect it, so `card.hold` (if any)
                // is now a stale id — `effectiveHold` must treat it as
                // suppressed so the fresh optimistic grant (correct id,
                // correct deadline) is what actually shows.
                releasedIDs = Set(card.hold.map { [$0.id] } ?? [])
                successPulse += 1
                // The hold committed the draft — the slider goes back to
                // tracking the hub, same as an untouched card, rather than
                // sitting frozen at what was just submitted (SF9).
                draftTouched = false
            case .notCommandable:
                problem = .message(HoldRefusal.notCommandable.message)
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
            // clear it from the screen immediately (review, 2026-08-15)
            // rather than waiting on the next frame, so a second tap on a
            // just-released hold isn't possible.
            _ = try await client.release(overrideId: overrideId)
            optimisticHold = nil
            releasedIDs.insert(overrideId)
            await HoldActivityController.shared.end(overrideId: overrideId)
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
}
