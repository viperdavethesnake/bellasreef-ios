// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Testing

@testable import BellasReefKit

/// UX review A4/A6: a proposed slider value must read as a proposal, and a
/// value under the fixture's 8 % floor must show what the hub will actually
/// do with it — snap it to 0 — rather than "Set to 5%".
@Suite("Dimming floor and proposal copy")
struct DimmingTests {
    @Test("under the floor snaps down to 0, never up; the floor itself is usable")
    func snap() {
        #expect(Dimming.snapPercent(5) == 0)
        #expect(Dimming.snapPercent(7.9) == 0)
        #expect(Dimming.snapPercent(8) == 8)
        #expect(Dimming.snapPercent(50) == 50)
        #expect(Dimming.snapPercent(0) == 0)
    }

    @Test("the floor is the hub's constant, not a guess")
    func floorValue() {
        // services/hardware_io/bellasreef_hardware_io/drivers/dimming.py: MIN_USABLE_DUTY = 0.08
        #expect(Dimming.minUsableDuty == 0.08)
    }

    @Test("a proposal equal to what the hub reports is not flagged")
    func matchesReported() {
        #expect(Dimming.proposalCaption(proposedPercent: 50, reportedDuty: 0.5) == nil)
    }

    @Test("a proposal that differs from the hub is marked as not applied")
    func differs() {
        #expect(Dimming.proposalCaption(proposedPercent: 50, reportedDuty: 0.0) == "not applied yet — tap Hold")
    }

    @Test("a sub-floor proposal says what will happen to it")
    func subFloor() {
        #expect(Dimming.proposalCaption(proposedPercent: 5, reportedDuty: 0.0) == "below 8% is off — this will hold at 0%")
        #expect(Dimming.proposalCaption(proposedPercent: 5, reportedDuty: 0.5) == "below 8% is off — this will hold at 0%")
    }

    @Test("no report yet: a proposal is still a proposal")
    func noReport() {
        #expect(Dimming.proposalCaption(proposedPercent: 30, reportedDuty: nil) == "not applied yet — tap Hold")
    }
}
