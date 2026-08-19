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
    /// `name` is the adopted device's display name, or the raw id when the
    /// frame has no adopted device behind it (the orphan-frame case) — the
    /// same fallback `.adoptedSilent` already used, so a device no longer
    /// renames itself the moment its first frame arrives.
    case reporting(id: String, name: String, frame: Components.Schemas.StateFrame)
    case adoptedSilent(id: String, name: String)

    public var id: String {
        switch self {
        case let .reporting(id, _, _): id
        case let .adoptedSilent(id, _): id
        }
    }
}

/// Merge the registry (what is adopted) with the stream (what has reported).
///
/// `devices` and `frames` disagree by design: the registry is REST truth
/// fetched on open/foreground, the frame dictionary is only ever what has
/// actually arrived over the socket since connect. Every adopted actuator
/// device (`actuator_class != nil` **and** `adopted == true`) appears exactly
/// once — a detached actuator still carries its `actuatorClass` (unbind is
/// not a delete; see `SystemView.detachedRow`), so `actuatorClass != nil`
/// alone lets a released channel keep showing as live equipment on the tab
/// that commands it. `.reporting` when
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
    roles: [String: String],
    registryLoaded: Bool = false
) -> [(role: String, rows: [EquipmentRow])] {
    var byRole: [String: [EquipmentRow]] = [:]
    var accountedFor: Set<String> = []

    let adopted = devices
        .filter { $0.actuatorClass != nil && $0.adopted == true }
        .sorted { $0.deviceId < $1.deviceId }
    // A frame for a device the registry knows and says is not adopted is a
    // stale frame, not equipment: the channel is under nobody's command, and
    // the frame is the safe-state publish from the unadopt itself
    // (2026-08-18: "Other Light" sat under Unassigned at 0 % after David
    // unadopted it). Once the registry has loaded, the same goes for a frame
    // nobody in the registry answers to. Before it has loaded, an unknown
    // frame still shows — that load race is what the fall-through below was
    // written for.
    let notAdopted = Set(devices.filter { $0.adopted != true }.map(\.deviceId))
    let known = Set(devices.map(\.deviceId))

    for device in adopted {
        let id = device.deviceId
        accountedFor.insert(id)
        let role = roles[id] ?? ""
        let name = device.displayName ?? id
        let row: EquipmentRow = if let frame = frames[id] {
            .reporting(id: id, name: name, frame: frame)
        } else {
            .adoptedSilent(id: id, name: name)
        }
        byRole[role, default: []].append(row)
    }

    for (id, frame) in frames where !accountedFor.contains(id) {
        if notAdopted.contains(id) { continue }
        if registryLoaded && !known.contains(id) { continue }
        let role = roles[id] ?? ""
        byRole[role, default: []].append(.reporting(id: id, name: id, frame: frame))
    }

    let husbandry = ["light", "heater", "pump", "doser", "outlet"]
    var out: [(role: String, rows: [EquipmentRow])] = []
    for role in husbandry {
        guard let rows = byRole[role], !rows.isEmpty else { continue }
        out.append((role: role, rows: rows.sorted { $0.id < $1.id }))
    }
    for (role, rows) in byRole.sorted(by: { $0.key < $1.key })
    where !husbandry.contains(role) && !rows.isEmpty {
        out.append((role: role, rows: rows.sorted { $0.id < $1.id }))
    }
    return out
}
