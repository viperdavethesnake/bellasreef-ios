// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

@Suite("ScheduleCurve — the engine's duty_at, ported")
struct ScheduleCurveTests {

    /// 08:00 → 20%, 20:00 → 80%, UTC. Same shape the backend's own
    /// profile tests use: one rising day segment, one wrap segment.
    private var curve: ScheduleCurve {
        ScheduleCurve(
            points: [.init(seconds: 28_800, duty: 0.2), .init(seconds: 72_000, duty: 0.8)],
            zoneIdentifier: "UTC"
        )!
    }

    /// A UTC instant on 2026-08-23 at the given seconds-of-day, built from
    /// components so no hand-computed epoch constant can be wrong.
    private func utc(_ secondsOfDay: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 23
        comps.hour = secondsOfDay / 3600
        comps.minute = secondsOfDay % 3600 / 60
        comps.second = secondsOfDay % 60
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }

    @Test("a point's own instant returns its duty")
    func atAPoint() {
        #expect(curve.duty(at: utc(28_800)) == 0.2)
    }

    @Test("duty(atSecondsToday:) agrees with duty(at:) for the same instant")
    func atSecondsToday() {
        #expect(curve.duty(atSecondsToday: 50_400) == curve.duty(at: utc(50_400)))
    }

    @Test("the day segment interpolates linearly")
    func daySegment() {
        // 14:00 is halfway from 08:00 to 20:00.
        #expect(abs(curve.duty(at: utc(50_400)) - 0.5) < 1e-9)
    }

    @Test("the wrap segment interpolates through midnight — no step at the darkest hour")
    func wrapSegment() {
        // 20:00→08:00(+1d) spans 12h; 02:00 is 6h in — halfway from 0.8 to 0.2.
        #expect(abs(curve.duty(at: utc(7_200)) - 0.5) < 1e-9)
        // The last point itself sits on the wrap segment (now_s >= last).
        #expect(curve.duty(at: utc(72_000)) == 0.8)
    }

    @Test("the instant is converted into the schedule's zone before lookup")
    func zoneConversion() {
        let pacific = ScheduleCurve(
            points: [.init(seconds: 28_800, duty: 0.2), .init(seconds: 72_000, duty: 0.8)],
            zoneIdentifier: "America/Los_Angeles"
        )!
        // 2026-08-23T15:00:00Z is 08:00 PDT — exactly the first point.
        #expect(pacific.duty(at: utc(54_000)) == 0.2)
    }

    @Test("plotPoints closes the day: identical synthesized values at 0 and 86400")
    func plotPointsEndpoints() {
        let plotted = curve.plotPoints
        #expect(plotted.first!.seconds == 0)
        #expect(plotted.last!.seconds == 86_400)
        // Midnight is 4h into the 12h wrap from 0.8 to 0.2 → 0.6.
        #expect(abs(plotted.first!.duty - 0.6) < 1e-9)
        #expect(plotted.first!.duty == plotted.last!.duty)
        #expect(plotted.count == 4)
    }

    @Test("a first point at second 0 is not duplicated by plotPoints")
    func plotPointsFirstAtMidnight() {
        let flat = ScheduleCurve(
            points: [.init(seconds: 0, duty: 0.1), .init(seconds: 43_200, duty: 0.9)],
            zoneIdentifier: "UTC"
        )!
        #expect(flat.plotPoints.map(\.seconds) == [0, 43_200, 86_400])
        #expect(flat.plotPoints.last!.duty == flat.plotPoints.first!.duty)
    }

    @Test("nextPoint walks forward and wraps")
    func nextPointWraps() {
        #expect(curve.nextPoint(after: utc(50_400)).seconds == 72_000)  // 14:00 → 20:00
        #expect(curve.nextPoint(after: utc(75_600)).seconds == 28_800)  // 21:00 → 08:00
    }

    @Test("wire time round-trips, tolerating HH:MM")
    func wireTime() {
        #expect(ScheduleCurve.seconds(fromWireTime: "08:00:00") == 28_800)
        #expect(ScheduleCurve.seconds(fromWireTime: "08:00") == 28_800)
        #expect(ScheduleCurve.seconds(fromWireTime: "24:00:00") == nil)
        #expect(ScheduleCurve.seconds(fromWireTime: "nonsense") == nil)
        #expect(ScheduleCurve.wireTime(fromSeconds: 28_800) == "08:00:00")
    }

    @Test("invalid curves refuse to construct, matching the hub's validate_curve")
    func invalidCurves() {
        // one point is a constant, not a schedule
        #expect(ScheduleCurve(points: [.init(seconds: 0, duty: 0.5)], zoneIdentifier: "UTC") == nil)
        // times must strictly ascend
        #expect(ScheduleCurve(
            points: [.init(seconds: 100, duty: 0.5), .init(seconds: 100, duty: 0.6)],
            zoneIdentifier: "UTC") == nil)
        // duty is 0...1
        #expect(ScheduleCurve(
            points: [.init(seconds: 0, duty: 0.5), .init(seconds: 100, duty: 1.2)],
            zoneIdentifier: "UTC") == nil)
        // the zone must resolve
        #expect(ScheduleCurve(
            points: [.init(seconds: 0, duty: 0.5), .init(seconds: 100, duty: 0.6)],
            zoneIdentifier: "Neptune/Trench") == nil)
    }

    /// The only production entry point — the rest of the suite constructs
    /// via `init?(points:zoneIdentifier:)`, which the API never calls.
    @Test("the wire initializer round-trips through Components.Schemas.ScheduleView")
    func wireInitializer() throws {
        let schedule = Components.Schemas.ScheduleView(
            anchor: .clock,
            assignedChannels: [],
            id: "11111111-1111-1111-1111-111111111111",
            locale: nil,
            name: "Test",
            points: [
                .init(at: "08:00:00", duty: 0.2),
                .init(at: "20:00:00", duty: 0.8),
            ],
            zone: "UTC"
        )
        let curve = try #require(ScheduleCurve(schedule))
        #expect(curve.duty(at: utc(28_800)) == 0.2)
    }

    @Test("the wire initializer refuses a malformed point time")
    func wireInitializerMalformedTime() {
        let schedule = Components.Schemas.ScheduleView(
            anchor: .clock,
            assignedChannels: [],
            id: "11111111-1111-1111-1111-111111111111",
            locale: nil,
            name: "Test",
            points: [
                .init(at: "nonsense", duty: 0.2),
                .init(at: "20:00:00", duty: 0.8),
            ],
            zone: "UTC"
        )
        #expect(ScheduleCurve(schedule) == nil)
    }

    /// Every other test's curve has exactly two points, so the bracketing
    /// loop only ever sees one `(lo, hi)` pair. This one has four, so segment
    /// SELECTION — not just interpolation — is exercised.
    @Test("a multi-point curve selects the correct bracketing segment")
    func multiSegmentSelection() {
        let curve = ScheduleCurve(
            points: [
                .init(seconds: 0, duty: 0.0),
                .init(seconds: 28_800, duty: 0.2),
                .init(seconds: 50_400, duty: 1.0),
                .init(seconds: 72_000, duty: 0.3),
            ],
            zoneIdentifier: "UTC"
        )!
        // 39,600 is halfway between the second and third points (28,800→50,400).
        #expect(abs(curve.duty(at: utc(39_600)) - 0.6) < 1e-9)
        // 61,200 is halfway between the third and fourth points (50,400→72,000) —
        // a different segment again, proving selection isn't just "first match".
        #expect(abs(curve.duty(at: utc(61_200)) - 0.65) < 1e-9)
    }
}
