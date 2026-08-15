// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation

/// One row in the Equipment section.
///
/// A state frame says what an actuator is doing, never that it exists — an
/// actuator adopted but never yet heard from on the stream is real equipment,
/// not nothing. Modelling that as its own case (rather than a frame filled
/// with invented zeros) is what keeps `.adoptedSilent` from ever claiming a
/// duty we do not have.
public enum EquipmentRow: Equatable, Identifiable {
    case reporting(id: String, frame: Components.Schemas.StateFrame)
    case adoptedSilent(id: String, name: String)

    public var id: String {
        switch self {
        case let .reporting(id, _): id
        case let .adoptedSilent(id, _): id
        }
    }
}

/// Merge the registry (what is adopted) with the stream (what has reported).
///
/// `devices` and `frames` disagree by design: the registry is REST truth
/// fetched on open/foreground, the frame dictionary is only ever what has
/// actually arrived over the socket since connect. Every adopted actuator
/// device (`actuator_class != nil`) appears exactly once — `.reporting` when
/// `frames` has an entry keyed by its `device_id` (that is the wire's
/// `actuator_id`; hardware-io registers `actuator_id = device_id`, see
/// `TankMonitor.channels`), `.adoptedSilent` otherwise. A frame whose key
/// matches no adopted device still appears, grouped under its streamed role —
/// today's behaviour, preserved rather than regressed.
///
/// Sections keep the husbandry order (`light, heater, pump, doser, outlet`),
/// with anything this build does not recognise — including `""`, Unassigned —
/// sorted after by role name. This is the same ordering `ActuatorSections`
/// already used for frames alone; merging in the registry does not change it.
public func equipmentRows(
    devices: [Components.Schemas.DeviceView],
    frames: [String: Components.Schemas.StateFrame],
    roles: [String: String]
) -> [(role: String, rows: [EquipmentRow])] {
    var byRole: [String: [EquipmentRow]] = [:]
    var accountedFor: Set<String> = []

    let adopted = devices
        .filter { $0.actuatorClass != nil }
        .sorted { $0.deviceId < $1.deviceId }

    for device in adopted {
        let id = device.deviceId
        accountedFor.insert(id)
        let role = roles[id] ?? ""
        let row: EquipmentRow = if let frame = frames[id] {
            .reporting(id: id, frame: frame)
        } else {
            .adoptedSilent(id: id, name: device.displayName ?? id)
        }
        byRole[role, default: []].append(row)
    }

    for (id, frame) in frames where !accountedFor.contains(id) {
        let role = roles[id] ?? ""
        byRole[role, default: []].append(.reporting(id: id, frame: frame))
    }

    let known = ["light", "heater", "pump", "doser", "outlet"]
    var out: [(role: String, rows: [EquipmentRow])] = []
    for role in known {
        guard let rows = byRole[role], !rows.isEmpty else { continue }
        out.append((role: role, rows: rows.sorted { $0.id < $1.id }))
    }
    for (role, rows) in byRole.sorted(by: { $0.key < $1.key })
    where !known.contains(role) && !rows.isEmpty {
        out.append((role: role, rows: rows.sorted { $0.id < $1.id }))
    }
    return out
}
