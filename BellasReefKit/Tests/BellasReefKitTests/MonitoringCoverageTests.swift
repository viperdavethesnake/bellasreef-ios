// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Testing

@testable import BellasReefKit

/// UX review A1: "All clear" showed identically for a probe inside its band
/// and a probe with no band at all. Silence watching runs unconditionally, so
/// something *is* monitored either way — but the postures differ and the line
/// should say so.
@Suite("Monitoring coverage note")
struct MonitoringCoverageTests {
    @Test("every reporting probe has a band: nothing to add")
    func allBanded() {
        let note = MonitoringCoverage.note(sensorIds: ["a", "b"]) { _ in true }
        #expect(note == nil)
    }

    @Test("no probe has a band: say thresholds are not set")
    func noneBanded() {
        let note = MonitoringCoverage.note(sensorIds: ["a"]) { _ in false }
        #expect(note == "no thresholds set")
    }

    @Test("some without a band: count them")
    func someBanded() {
        let note = MonitoringCoverage.note(sensorIds: ["a", "b", "c"]) { $0 == "a" }
        #expect(note == "2 of 3 sensors without thresholds")
    }

    @Test("no probes at all: nothing to say — that is the status line's job")
    func none() {
        #expect(MonitoringCoverage.note(sensorIds: []) { _ in true } == nil)
    }
}
