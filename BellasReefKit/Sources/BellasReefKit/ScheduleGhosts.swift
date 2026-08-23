// Bella's Reef iOS — closed source.

import BellasReefAPI

/// Channels a schedule is assigned to that no adopted light currently claims.
/// Assignment survives unadopt/forget on the hub by design (spec 2026-08-19);
/// these are the ids every adopted-filtered surface goes blind to — the 2026-08-23
/// UX review's MF1. Pure set arithmetic so it can carry a test.
public enum ScheduleGhosts {
    /// `assigned` minus whichever of those ids `devices` currently reports as
    /// adopted. Sorted so a caller gets stable output rather than set order.
    ///
    /// `devicesKnown` must be false whenever the catalog hasn't actually
    /// loaded (idle, loading, or failed) — final-review finding: a caller
    /// that defaults an unloaded catalog to `[]` makes every assigned
    /// channel look like a ghost, which invites a destructive unassign on
    /// false information. Unknown is its own answer, not "all ghosts", so
    /// this returns `[]` rather than guessing when the catalog can't yet
    /// speak for what's adopted.
    public static func channels(
        assigned: [String],
        devices: [Components.Schemas.DeviceView],
        devicesKnown: Bool
    ) -> [String] {
        guard devicesKnown else { return [] }
        let adopted = Set(devices.filter { $0.adopted == true }.map(\.deviceId))
        return assigned.filter { !adopted.contains($0) }.sorted()
    }
}
