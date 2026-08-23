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

    @Test("percent rounds instead of truncating — 0.29 is 29, not 28")
    func percentRounds() {
        #expect(Dimming.percent(0.29) == 29)
        #expect(Dimming.percent(0.005) == 1)
        #expect(Dimming.percent(0.0) == 0)
        #expect(Dimming.percent(1.0) == 100)
    }

    @Test("convergence caption appears only while meaningfully apart")
    func convergenceCaption() {
        #expect(Dimming.convergenceCaption(reportedDuty: 0.45, targetDuty: 0.79) ==
                "Catching up to the schedule — now 45%, heading to 79%")
        #expect(Dimming.convergenceCaption(reportedDuty: 0.79, targetDuty: 0.792) == nil)
        #expect(Dimming.convergenceCaption(reportedDuty: nil, targetDuty: 0.5) == nil)
        #expect(Dimming.convergenceCaption(reportedDuty: 0.5, targetDuty: nil) == nil)
    }

    /// The threshold is a strict `>`, not `>=` — a gap of exactly the
    /// threshold reads as arrived, not still catching up. 0.0/0.01 is chosen
    /// (rather than e.g. 0.79/0.80) because it is one of the few pairs whose
    /// `Double` subtraction lands on exactly 0.01 rather than a value a hair
    /// above it — the point being tested is the `>` itself, not a rounding
    /// artifact one way or the other.
    @Test("convergence caption at exactly the threshold is nil, not shown")
    func convergenceCaptionAtThreshold() {
        #expect(Dimming.convergenceCaption(reportedDuty: 0.0, targetDuty: 0.01) == nil)
    }

    @Test("floor footnote is composed from the floor, exact string")
    func floorFootnoteText() {
        #expect(Dimming.floorFootnote ==
                "Below 8% this dimmer is off — points under 8% run at 0%.")
    }
}
