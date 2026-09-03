// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation

/// One card on the Lighting tab: one adopted `light`-role actuator, the
/// hub's own reported duty, and any active manual hold.
///
/// Pure, like `equipmentRows` — no frame is invented for a device the stream
/// has not spoken for yet. `reportedDuty == nil` is that "no state yet"
/// shape; it is not the same as a reported 0%, and a card must not blur the
/// two (mirrors `EquipmentRow.adoptedSilent`).
public struct LightingCard: Equatable, Identifiable, Sendable {
    /// The hub's record of a live manual hold, carried on the state frame's
    /// `override` (`TankView`'s "Held at X% · remaining" already reads the
    /// same field — this just gives it a stable shape here too).
    ///
    /// `id` is `OverrideContext.id` off the same frame — required on the
    /// wire (`components/schemas/OverrideContext` lists it non-optional), so
    /// it is always present whenever `hold` is non-nil. That makes Release
    /// unconditional: the id a card shows a hold with is the id that ends
    /// it, regardless of which client placed it — there is no
    /// "held by another device, can't release from here" case to invent,
    /// because the wire never scopes an override to its creator.
    ///
    /// Carries `expiresAt` (also required on `OverrideContext`), not a
    /// snapshot second-count: a static "remaining seconds" captured at frame
    /// receipt freezes the moment the wire goes quiet during an otherwise
    /// steady hold, which is exactly the dishonest "it looks stopped but
    /// isn't" the countdown must not do (review fold, 2026-08-15). Whatever
    /// renders this ticks it live against `Date()` instead.
    public struct ActiveHold: Equatable, Sendable {
        public let id: String
        public let duty: Double
        public let expiresAt: Date
        /// How this hold arrives and how it will leave — snap or ramp
        /// (backend spec 2026-08-17). Off `OverrideContext.transition`,
        /// required on the wire, so always present whenever `hold` is.
        public let transition: HubClient.HoldTransition

        public init(
            id: String, duty: Double, expiresAt: Date, transition: HubClient.HoldTransition
        ) {
            self.id = id
            self.duty = duty
            self.expiresAt = expiresAt
            self.transition = transition
        }
    }

    /// The curve this channel is playing, when one is assigned — id and
    /// name straight off the wire, the points parsed into `ScheduleCurve`.
    /// `nil` covers both no-assignment and a schedule this client could not
    /// parse (unknown zone, malformed time): absent renders honestly, a
    /// guessed curve would not.
    public struct AssignedSchedule: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let curve: ScheduleCurve

        public init(id: String, name: String, curve: ScheduleCurve) {
            self.id = id
            self.name = name
            self.curve = curve
        }
    }

    public let id: String
    public let name: String
    public let reportedDuty: Double?
    public let hold: ActiveHold?
    /// The cap the duration menu must respect. `nil` only if the hub omitted
    /// it — an authoritative actuator is required to declare one at
    /// registration (device-classes.md §2), so this is defensive rather than
    /// an expected shape.
    public let maxRuntimeS: Double?
    public let schedule: AssignedSchedule?

    public init(
        id: String, name: String, reportedDuty: Double?, hold: ActiveHold?, maxRuntimeS: Double?,
        schedule: AssignedSchedule? = nil
    ) {
        self.id = id
        self.name = name
        self.reportedDuty = reportedDuty
        self.hold = hold
        self.maxRuntimeS = maxRuntimeS
        self.schedule = schedule
    }
}

/// Is this registry row a light this operator can command?
///
/// Adopted `light`-role actuators only. A detached light (`adopted == false`)
/// is not one: unbind is not a delete, and a channel someone else could
/// reclaim is not this operator's to command.
///
/// Named and public rather than left inline in `lightingCards`' filter,
/// because the Lighting tab is no longer the only thing that has to agree on
/// what a light is — the App Intents `LightQuery` (UX review D3) offers the
/// same set to Siri, Spotlight and Shortcuts, and two copies of this
/// predicate would be two answers to one question.
public func isLight(_ device: Components.Schemas.DeviceView) -> Bool {
    device.adopted == true && device.role == "light"
}

/// Merge the registry and the stream into the Lighting tab's card list.
///
/// Adopted `light`-role actuators only — `equipmentRows` renders every role
/// on one shared Tank/Equipment surface, but the Lighting tab is a control
/// surface for lights specifically (spec Feature 2 layout). A detached light
/// (`adopted == false`) produces no card, same rule `equipmentRows` applies
/// for the same reason: unbind is not a delete, and a channel someone else
/// could reclaim is not this operator's to command.
///
/// Sorted the way `equipmentRows` actually sorts its rows — by device id, not
/// by display name; a renamed light must not reorder the list an operator
/// has already memorised the layout of.
public func lightingCards(
    devices: [Components.Schemas.DeviceView],
    frames: [String: Components.Schemas.StateFrame],
    schedules: [Components.Schemas.ScheduleView] = []
) -> [LightingCard] {
    devices
        .filter(isLight)
        .map { device in
            let frame = frames[device.deviceId]
            let assigned = schedules.first { $0.assignedChannels.contains(device.deviceId) }
            return LightingCard(
                id: device.deviceId,
                name: device.displayName ?? device.deviceId,
                reportedDuty: frame.map(reportedDuty(from:)),
                hold: frame?.override.map {
                    LightingCard.ActiveHold(
                        id: $0.id, duty: $0.duty, expiresAt: $0.expiresAt,
                        transition: HubClient.HoldTransition($0.transition)
                    )
                },
                maxRuntimeS: device.maxRuntimeS,
                schedule: assigned.flatMap { schedule in
                    ScheduleCurve(schedule).map {
                        LightingCard.AssignedSchedule(id: schedule.id, name: schedule.name, curve: $0)
                    }
                }
            )
        }
        .sorted { $0.id < $1.id }
}

/// How a frame's `level` becomes "what fraction is this channel driven at" —
/// the same switch `TankView`'s equipment row already performs, exhaustive
/// over both actuator level kinds so a new one is a compile error here
/// rather than a channel silently rendering as 0%.
private func reportedDuty(from frame: Components.Schemas.StateFrame) -> Double {
    switch frame.payload.level {
    case let .pwm(level): level.duty
    case let .binary(level): level.on ? 1 : 0
    }
}

/// A duration preset for the Lighting tab's Hold menu, in seconds
/// (15 min / 1 h / 4 h / 8 h — spec Feature 2). "Custom" is a UI-only option
/// layered on top by the view, numerically bounded the same way; it carries
/// no fixed length here to be a case of.
public enum DurationPreset: Double, CaseIterable, Sendable {
    case fifteenMinutes = 900
    case oneHour = 3600
    case fourHours = 14_400
    case eightHours = 28_800
}

/// The hold a Lighting card actually shows, reconciling the frame's own
/// account against a client's local optimistic state — a grant just placed,
/// or ids this client already knows are stale. Pure and extracted (review
/// round 2, 2026-08-15) after two bugs were found in this exact seam when it
/// lived as a view-local computed property: pinning the precedence here lets
/// each scenario carry its own test rather than only being reasoned about
/// against `@State`.
///
/// Precedence:
/// 1. The frame's own hold, unless its id is in `releasedIDs` — either
///    genuinely released by this client, or superseded by a newer local
///    grant at the same duty. The engine's deadband can leave the frame
///    reporting the *previous* hold for a while after a re-hold, because a
///    same-duty re-hold produces no new telemetry to publish; `releasedIDs`
///    is how a caller tells this function "that id is stale, don't trust it
///    even though the frame still carries it."
/// 2. Otherwise the optimistic hold, unless it is itself in `releasedIDs`,
///    or has already expired as of `now`. An unexpired optimistic grant is
///    the honest stand-in while the frame hasn't caught up yet; one that has
///    passed its own deadline must not go on rendering as a live hold just
///    because no fresher frame ever arrived to say otherwise (a quiet
///    stream, or a hold that expired for real) — a caller ticking `now`
///    forward (e.g. a `TimelineView`) is what turns this into a live
///    countdown that eventually clears itself rather than a phantom.
/// 3. Otherwise nothing is held.
public func effectiveHold(
    frameHold: LightingCard.ActiveHold?,
    optimisticHold: LightingCard.ActiveHold?,
    releasedIDs: Set<String>,
    now: Date
) -> LightingCard.ActiveHold? {
    if let frameHold, !releasedIDs.contains(frameHold.id) {
        return frameHold
    }
    if let optimisticHold, !releasedIDs.contains(optimisticHold.id), optimisticHold.expiresAt > now {
        return optimisticHold
    }
    return nil
}

/// Presets legal for a target whose `max_runtime_s` is `maxRuntimeS`.
///
/// `nil` means the hub reported no ceiling — every preset is offered rather
/// than none, since withholding all of them would read as a bug, not caution.
/// In practice a `light`-role actuator is authoritative and always declares
/// one (device-classes.md §2); this is the defensive branch, not the
/// expected one.
public func allowedDurations(maxRuntimeS: Double?) -> [DurationPreset] {
    guard let cap = maxRuntimeS else { return DurationPreset.allCases }
    return DurationPreset.allCases.filter { $0.rawValue <= cap }
}

/// The longest hold this target will accept, in whole minutes: the hub's
/// documented ceiling and this device's own declared `max_runtime_s`,
/// whichever is lower. The same rule `allowedDurations` applies to the
/// presets, for the arbitrary minute counts a custom duration or a shortcut
/// can produce.
///
/// Both halves have to be checked here, because nothing below this client
/// checks the second one. `POST /api/v1/overrides` gates on `observe_only`
/// authority and on clock trust and on nothing else — it does not compare
/// `duration_s` against the target's `max_runtime_s`. Downstream,
/// hardware-io's `_runtime_deadline` latches its guard once a hold outlives
/// `max_runtime_s`, and there is no automatic path back out. So an
/// over-runtime hold is accepted, and then latches a channel: the client is
/// the only thing standing between the operator and that, which is why this
/// cap exists and why every door onto a hold has to go through it.
///
/// The `nil` branch is defensive rather than expected — an authoritative
/// `light`-role actuator declares a runtime at registration
/// (device-classes.md §2) — and falls back to the spec's own ceiling rather
/// than to no ceiling at all.
///
/// Whole-minute truncation, never rounding up: a rounded-up cap is a number
/// the hub would refuse.
///
/// Floored at one minute, which is the spec's own smallest hold
/// (`duration_s` carries `exclusiveMinimum: 0`, so one whole minute is the
/// floor `IntentSupport.minHoldMinutes` names). Truncation alone returns 0
/// for any runtime under a minute, and a cap of 0 is not a number this
/// function can honestly return: every sentence built on it reads "between 1
/// and 0 minutes" and every field seeded from it starts invalid. A
/// sub-minute `max_runtime_s` is a device declaring that no hold this client
/// can express fits inside it; the honest answer is the smallest hold there
/// is, and the hub refusing it, rather than a range with no members.
public func holdMinutesCap(maxRuntimeS: Double?) -> Int {
    guard let maxRuntimeS, maxRuntimeS > 0 else { return IntentSupport.maxHoldMinutes }
    return max(
        IntentSupport.minHoldMinutes, min(IntentSupport.maxHoldMinutes, Int(maxRuntimeS / 60))
    )
}
