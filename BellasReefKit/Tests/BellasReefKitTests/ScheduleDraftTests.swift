// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

@Suite("ScheduleDraft — the editor's rules, hoisted out of the view")
struct ScheduleDraftTests {

    private func draft(
        name: String = "Reef",
        points: [ScheduleDraft.DraftPoint] = [
            .init(seconds: 28_800, dutyPercentText: "20"),
            .init(seconds: 72_000, dutyPercentText: "80"),
        ],
        zone: String = "UTC"
    ) -> ScheduleDraft {
        ScheduleDraft(name: name, points: points, zoneIdentifier: zone)
    }

    // MARK: validate()

    @Test("an empty name fails first, even with otherwise-valid points")
    func emptyName() {
        let result = draft(name: "   ").validate()
        guard case .failure(let invalid) = result else {
            Issue.record("expected failure"); return
        }
        #expect(invalid.message == "The schedule needs a name.")
    }

    @Test("an unparseable or out-of-range duty fails")
    func badDuty() {
        let unparseable = draft(points: [
            .init(seconds: 0, dutyPercentText: "abc"),
            .init(seconds: 100, dutyPercentText: "50"),
        ]).validate()
        guard case .failure(let invalid) = unparseable else {
            Issue.record("expected failure"); return
        }
        #expect(invalid.message == "Brightness is 0–100%.")

        let outOfRange = draft(points: [
            .init(seconds: 0, dutyPercentText: "101"),
            .init(seconds: 100, dutyPercentText: "50"),
        ]).validate()
        guard case .failure(let invalid2) = outOfRange else {
            Issue.record("expected failure"); return
        }
        #expect(invalid2.message == "Brightness is 0–100%.")
    }

    @Test("a point at or past 86_400 s fails — that would wire-encode to an invalid 24:00:00+ time")
    func pointTimeOutOfRange() {
        let atMidnightNextDay = draft(points: [
            .init(seconds: 0, dutyPercentText: "20"),
            .init(seconds: 86_400, dutyPercentText: "80"),
        ]).validate()
        guard case .failure(let invalid) = atMidnightNextDay else {
            Issue.record("expected failure"); return
        }
        #expect(invalid.message == "A point's time must be within one day.")

        let wellPast = draft(points: [
            .init(seconds: 0, dutyPercentText: "20"),
            .init(seconds: 90_000, dutyPercentText: "80"),
        ]).validate()
        guard case .failure(let invalid2) = wellPast else {
            Issue.record("expected failure"); return
        }
        #expect(invalid2.message == "A point's time must be within one day.")
    }

    @Test("two points at the same time fail, even when both have legal duties")
    func duplicateTimes() {
        let result = draft(points: [
            .init(seconds: 100, dutyPercentText: "20"),
            .init(seconds: 100, dutyPercentText: "80"),
        ]).validate()
        guard case .failure(let invalid) = result else {
            Issue.record("expected failure"); return
        }
        #expect(invalid.message == "Two points share a time.")
    }

    @Test("fewer than two points fails")
    func tooFewPoints() {
        let result = draft(points: [.init(seconds: 0, dutyPercentText: "50")]).validate()
        guard case .failure(let invalid) = result else {
            Issue.record("expected failure"); return
        }
        #expect(invalid.message == "A curve needs at least two points.")
    }

    @Test("zero points fails with the two-points message, not the duplicate-time one")
    func zeroPoints() {
        let result = draft(points: []).validate()
        guard case .failure(let invalid) = result else {
            Issue.record("expected failure"); return
        }
        #expect(invalid.message == "A curve needs at least two points.")
    }

    @Test("a valid draft succeeds: sorted, wire-encoded, trimmed, duty as a fraction")
    func validDraft() throws {
        let result = draft(
            name: "  Reef  ",
            points: [
                .init(seconds: 72_000, dutyPercentText: "80"),
                .init(seconds: 28_800, dutyPercentText: "20"),
            ],
            zone: "America/Los_Angeles"
        ).validate()
        guard case .success(let request) = result else {
            Issue.record("expected success"); return
        }
        #expect(request.name == "Reef")
        #expect(request.zone == "America/Los_Angeles")
        #expect(request.points.map(\.at) == ["08:00:00", "20:00:00"])
        #expect(request.points.map(\.duty) == [0.2, 0.8])
    }

    // MARK: curvePreview

    @Test("a draft with valid points but an empty name still previews — validate() still fails")
    func previewIgnoresName() {
        let nameless = draft(name: "   ", points: [
            .init(seconds: 28_800, dutyPercentText: "20"),
            .init(seconds: 72_000, dutyPercentText: "80"),
        ])
        #expect(nameless.curvePreview != nil)
        guard case .failure(let invalid) = nameless.validate() else {
            Issue.record("expected validate() to still fail on the empty name"); return
        }
        #expect(invalid.message == "The schedule needs a name.")
    }

    @Test("curvePreview is nil when the points themselves don't validate")
    func previewNilOnBadPoints() {
        #expect(draft(points: [.init(seconds: 0, dutyPercentText: "50")]).curvePreview == nil)
        #expect(draft(points: [
            .init(seconds: 0, dutyPercentText: "abc"),
            .init(seconds: 100, dutyPercentText: "50"),
        ]).curvePreview == nil)
    }

    // MARK: secondsOfDay / date — fixed UTC reference day

    @Test("a 02:30 point round-trips to 9_000 s and back, on an arbitrary calendar day")
    func secondsOfDayRoundTrip() {
        #expect(ScheduleDraft.secondsOfDay(from: ScheduleDraft.date(secondsOfDay: 9_000)) == 9_000)
    }

    @Test("date(secondsOfDay:) reads 02:30 in GMT regardless of the device's zone")
    func dateIsGMTAnchored() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let comps = calendar.dateComponents(
            [.hour, .minute], from: ScheduleDraft.date(secondsOfDay: 9_000)
        )
        #expect(comps.hour == 2)
        #expect(comps.minute == 30)
    }

    @Test("secondsOfDay is immune to the device's own DST transitions — a fixed GMT day has none")
    func noDSTDrift() {
        // 2026-03-08 is the US spring-forward date; a device-zone anchor
        // (e.g. Calendar.current.startOfDay) risks landing inside or across
        // the gap. The fixed reference day never moves, so this is exactly
        // the ordinary round trip, just spelled out on that date's worth of
        // seconds to make the intent explicit.
        for seconds in [0, 9_000, 28_800, 43_200, 72_000, 86_340] {
            #expect(ScheduleDraft.secondsOfDay(from: ScheduleDraft.date(secondsOfDay: seconds)) == seconds)
        }
    }

    // MARK: nextFreeTime()

    @Test("an hour after the latest point, capped at 86_340")
    func nextFreeTimeDefault() {
        #expect(draft(points: [.init(seconds: 28_800, dutyPercentText: "20")]).nextFreeTime() == 32_400)
        #expect(draft(points: [.init(seconds: 86_000, dutyPercentText: "20")]).nextFreeTime() == 86_340)
    }

    @Test("no points at all targets 3_600 (one hour after midnight)")
    func nextFreeTimeEmpty() {
        #expect(draft(points: []).nextFreeTime() == 3_600)
    }

    @Test("the cap taken returns the nearest free minute below it")
    func nextFreeTimeCapTaken() {
        let points = [
            ScheduleDraft.DraftPoint(seconds: 86_000, dutyPercentText: "20"),
            ScheduleDraft.DraftPoint(seconds: 86_340, dutyPercentText: "30"),
        ]
        #expect(draft(points: points).nextFreeTime() == 86_280)
    }

    @Test("nil when every minute from the cap down to midnight is taken")
    func nextFreeTimeExhausted() {
        var points: [ScheduleDraft.DraftPoint] = []
        var seconds = 0
        while seconds <= 86_340 {
            points.append(.init(seconds: seconds, dutyPercentText: "50"))
            seconds += 60
        }
        #expect(draft(points: points).nextFreeTime() == nil)
    }
}
