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
    public struct ActiveHold: Equatable, Sendable {
        public let duty: Double
        public let remainingS: Double

        public init(duty: Double, remainingS: Double) {
            self.duty = duty
            self.remainingS = remainingS
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

    public init(
        id: String, name: String, reportedDuty: Double?, hold: ActiveHold?, maxRuntimeS: Double?
    ) {
        self.id = id
        self.name = name
        self.reportedDuty = reportedDuty
        self.hold = hold
        self.maxRuntimeS = maxRuntimeS
    }
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
    frames: [String: Components.Schemas.StateFrame]
) -> [LightingCard] {
    devices
        .filter { $0.adopted == true && $0.role == "light" }
        .map { device in
            let frame = frames[device.deviceId]
            return LightingCard(
                id: device.deviceId,
                name: device.displayName ?? device.deviceId,
                reportedDuty: frame.map(reportedDuty(from:)),
                hold: frame?.override.map {
                    LightingCard.ActiveHold(duty: $0.duty, remainingS: $0.expiresInS)
                },
                maxRuntimeS: device.maxRuntimeS
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
