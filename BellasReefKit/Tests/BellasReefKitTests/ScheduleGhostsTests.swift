// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

private enum ScheduleGhostsFixtures {
    static func device(id: String, adopted: Bool) -> Components.Schemas.DeviceView {
        .init(
            actuatorClass: "dimmer",
            adopted: adopted,
            deviceId: id,
            displayName: id,
            driverId: "pca9685",
            enabled: true,
            kind: "actuator"
        )
    }
}

/// UX review MF1: assignment survives unadopt/forget on the hub by design
/// (spec 2026-08-19), so a surface that filters to adopted devices only goes
/// blind to a schedule still assigned to a channel nobody claims any more.
/// `ScheduleGhosts.channels` is the assigned-minus-adopted set every such
/// surface needs to show the operator what it can no longer see on its own.
@Suite("ScheduleGhosts")
struct ScheduleGhostsTests {
    @Test("a channel assigned but not adopted is a ghost")
    func unadoptedChannelIsGhost() {
        let devices = [ScheduleGhostsFixtures.device(id: "pi-pwm-0", adopted: true)]
        #expect(ScheduleGhosts.channels(assigned: ["pca9685-0", "pi-pwm-0"], devices: devices, devicesKnown: true)
                == ["pca9685-0"])
    }

    @Test("no assignments means no ghosts")
    func emptyAssignedIsNoGhosts() {
        let devices = [ScheduleGhostsFixtures.device(id: "pi-pwm-0", adopted: true)]
        #expect(ScheduleGhosts.channels(assigned: [], devices: devices, devicesKnown: true) == [])
    }

    @Test("an unadopted device row present in devices still counts as a ghost")
    func unadoptedDeviceRowStillGhost() {
        let devices = [ScheduleGhostsFixtures.device(id: "pca9685-0", adopted: false)]
        #expect(ScheduleGhosts.channels(assigned: ["pca9685-0"], devices: devices, devicesKnown: true)
                == ["pca9685-0"])
    }

    /// Final-review finding: an unloaded catalog must not read as "all
    /// ghosts" — `devices` empty because it hasn't loaded yet looks
    /// identical, on its own, to `devices` empty because nothing is
    /// adopted. `devicesKnown: false` is what tells `channels` it's the
    /// former, and the honest answer is "don't know", not a false positive
    /// that invites unassigning a channel that may well be adopted.
    @Test("an unknown catalog reports no ghosts, not all-ghosts")
    func unknownCatalogIsNoGhosts() {
        #expect(ScheduleGhosts.channels(assigned: ["pca9685-0", "pi-pwm-0"], devices: [], devicesKnown: false)
                == [])
    }
}
