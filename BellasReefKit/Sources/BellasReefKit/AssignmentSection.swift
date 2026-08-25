// Bella's Reef iOS — closed source.

import BellasReefAPI

/// The editor's "Assigned" section, made honest (ruled 2026-08-25, at the
/// bench). Its predecessor was titled "Assigned lights" over a list of every
/// adopted light with a checkmark for the actually-assigned ones — candidates
/// read as assignments ("both lights show up as assigned"), toggling was
/// undiscoverable, and unassign was invisible. Now the section holds two
/// clearly different things: the assigned list is exactly what the schedule
/// names — adopted lights, detached ghosts, even channels with no registry
/// row left — and the Add menu is everything addable, with a light that
/// would be *moved* off another schedule saying so before it happens.
///
/// Pure set arithmetic over wire types, like `ScheduleGhosts` (whose
/// adopted/ghost split this absorbs for the editor's purposes), so every
/// distinction here carries a test.
public enum AssignmentSection {
    /// One channel the schedule names.
    public struct Assigned: Equatable, Sendable {
        public let channelId: String
        public let name: String
        public let subtitle: String?
        /// `true`: an adopted light. `false`: a ghost — the assignment
        /// survives on the hub while nothing claims the channel, and output
        /// resumes if it is adopted again. `nil`: the catalog has not
        /// loaded, so adoption is unknowable — render no ghost caption
        /// rather than guess (the same rule as `ScheduleGhosts.devicesKnown`:
        /// "all ghosts" on false information invites a destructive Remove).
        public let adopted: Bool?
    }

    /// One adopted light the schedule could take.
    public struct Candidate: Equatable, Sendable {
        public let channelId: String
        public let name: String
        public let subtitle: String
        /// The schedule this light is on now, when it is on one — picking it
        /// is a move, and the caller confirms before calling assign.
        public let currentScheduleName: String?
    }

    /// Exactly what the schedule names, in stable channel order. A channel
    /// with no registry row at all (Cleared; assignment kept by design,
    /// spec 2026-08-19) still gets a row — its id is all we know about it.
    public static func assigned(
        channelIds: [String],
        devices: [Components.Schemas.DeviceView],
        devicesKnown: Bool
    ) -> [Assigned] {
        channelIds.sorted().map { id in
            let device = devices.first { $0.deviceId == id }
            return Assigned(
                channelId: id,
                name: device?.displayName ?? id,
                subtitle: device.map {
                    DeviceSubtitle.text(driverId: $0.driverId, channel: $0.channel, role: nil)
                },
                adopted: devicesKnown ? (device?.adopted == true) : nil
            )
        }
    }

    /// Adopted lights not on this schedule, in stable id order. Sensors and
    /// detached rows are not addable — assignment is a promise of output.
    public static func candidates(
        for scheduleId: String,
        schedules: [Components.Schemas.ScheduleView],
        devices: [Components.Schemas.DeviceView]
    ) -> [Candidate] {
        let here = Set(schedules.first { $0.id == scheduleId }?.assignedChannels ?? [])
        return devices
            .filter { $0.adopted == true && $0.role == "light" && !here.contains($0.deviceId) }
            .sorted { $0.deviceId < $1.deviceId }
            .map { device in
                Candidate(
                    channelId: device.deviceId,
                    name: device.displayName ?? device.deviceId,
                    subtitle: DeviceSubtitle.text(
                        driverId: device.driverId, channel: device.channel, role: nil
                    ),
                    currentScheduleName: schedules
                        .first { $0.id != scheduleId && $0.assignedChannels.contains(device.deviceId) }?
                        .name
                )
            }
    }
}
