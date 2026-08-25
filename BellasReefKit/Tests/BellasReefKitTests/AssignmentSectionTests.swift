// Bella's Reef iOS — closed source.

import BellasReefAPI
import Testing

@testable import BellasReefKit

/// The editor's "Assigned" section, made honest (ruled 2026-08-25, at the
/// bench): the old section was titled "Assigned lights" over a list of every
/// adopted light — candidates read as assignments, toggling was
/// undiscoverable, and unassign was invisible. The new shape: the assigned
/// list holds exactly what the schedule names (adopted lights and ghosts
/// alike, one truth), and an explicit Add menu holds everything addable.
@Suite("Assignment section")
struct AssignmentSectionTests {
    private func light(
        _ id: String, name: String, channel: String, adopted: Bool = true,
        driverId: String = "pca9685", role: String? = "light"
    ) -> Components.Schemas.DeviceView {
        .init(
            actuatorClass: "dimmer",
            adopted: adopted,
            channel: channel,
            deviceId: id,
            displayName: name,
            driverId: driverId,
            enabled: true,
            kind: "actuator",
            role: role
        )
    }

    private func schedule(
        _ id: String, name: String, assigned: [String]
    ) -> Components.Schemas.ScheduleView {
        .init(
            anchor: .clock, assignedChannels: assigned, id: id, locale: nil,
            name: name, points: [.init(at: "08:00:00", duty: 0.5)], zone: "UTC"
        )
    }

    @Test("the assigned list holds exactly what the schedule names — adopted, ghost, and forgotten alike")
    func assignedListIsTheTruth() {
        let rows = AssignmentSection.assigned(
            channelIds: ["pca9685-0", "pi-pwm-0", "pi-pwm-3"],
            devices: [
                light("pca9685-0", name: "Light 1", channel: "0"),
                light("pi-pwm-0", name: "Meter Check", channel: "0",
                      adopted: false, driverId: "pi-pwm"),
                // pi-pwm-3 has no registry row at all — Cleared, assignment kept.
            ],
            devicesKnown: true
        )
        #expect(rows.map(\.channelId) == ["pca9685-0", "pi-pwm-0", "pi-pwm-3"])
        #expect(rows[0].name == "Light 1")
        #expect(rows[0].subtitle == "pca9685 · ch 0")
        #expect(rows[0].adopted == true)
        #expect(rows[1].name == "Meter Check")
        #expect(rows[1].adopted == false)
        #expect(rows[2].name == "pi-pwm-3")
        #expect(rows[2].subtitle == nil)
        #expect(rows[2].adopted == false)
    }

    @Test("an unloaded catalog cannot call anything a ghost — adoption reads unknown, rows still listed")
    func unknownCatalogMakesNoGhostClaims() {
        // Same reasoning as ScheduleGhosts.devicesKnown: defaulting an
        // unloaded catalog to [] would caption every assignment "not
        // adopted — output resumes…", inviting a Remove on false information.
        let rows = AssignmentSection.assigned(
            channelIds: ["pca9685-0"], devices: [], devicesKnown: false
        )
        #expect(rows.count == 1)
        #expect(rows[0].adopted == nil)
        #expect(rows[0].name == "pca9685-0")
    }

    @Test("candidates are adopted lights not on this schedule; one on another schedule carries its name")
    func candidatesForTheAddMenu() {
        let schedules = [
            schedule("s-1", name: "Brining", assigned: ["pca9685-0"]),
            schedule("s-2", name: "Dawn Test", assigned: ["pi-pwm-1"]),
        ]
        let candidates = AssignmentSection.candidates(
            for: "s-1",
            schedules: schedules,
            devices: [
                light("pca9685-0", name: "Light 1", channel: "0"),          // already on s-1
                light("pi-pwm-0", name: "Meter Check", channel: "0", driverId: "pi-pwm"),
                light("pi-pwm-1", name: "Frag Shelf", channel: "1", driverId: "pi-pwm"),
                light("pi-pwm-2", name: "Detached", channel: "2", adopted: false,
                      driverId: "pi-pwm"),                                   // not adopted
                light("ds18b20-x", name: "Probe", channel: "28-0", driverId: "ds18b20",
                      role: nil),                                            // not a light
            ]
        )
        #expect(candidates.map(\.channelId) == ["pi-pwm-0", "pi-pwm-1"])
        #expect(candidates[0].name == "Meter Check")
        #expect(candidates[0].subtitle == "pi-pwm · ch 0")
        #expect(candidates[0].currentScheduleName == nil)
        #expect(candidates[1].currentScheduleName == "Dawn Test")
    }
}
