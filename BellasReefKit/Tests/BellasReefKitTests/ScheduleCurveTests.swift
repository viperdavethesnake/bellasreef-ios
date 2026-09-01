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

    /// Perf refactor fence (`ScheduleCurve` now stores its `Calendar` at
    /// init instead of rebuilding one per call): the same instant/zone pair
    /// `zoneConversion` above uses, asserted directly against
    /// `secondsOfDay(for:)` rather than through `duty(at:)`, so a broken
    /// stored `Calendar` (wrong `timeZone`, wrong `identifier`) is caught
    /// even if `duty(at:)`'s own maths happened to mask it.
    @Test("secondsOfDay is unchanged by storing the Calendar at init")
    func secondsOfDayUsesStoredCalendar() {
        let pacific = ScheduleCurve(
            points: [.init(seconds: 28_800, duty: 0.2), .init(seconds: 72_000, duty: 0.8)],
            zoneIdentifier: "America/Los_Angeles"
        )!
        // 2026-08-23T15:00:00Z is 08:00:00 PDT.
        #expect(pacific.secondsOfDay(for: utc(54_000)) == 28_800)
    }

    /// A UTC instant on an arbitrary date, for the DST tests below where the
    /// fixed 2026-08-23 anchor `utc(_:)` uses does not apply.
    private func utcOn(_ year: Int, _ month: Int, _ day: Int, secondsOfDay: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = secondsOfDay / 3600
        comps.minute = secondsOfDay % 3600 / 60
        comps.second = secondsOfDay % 60
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }

    /// US spring-forward, 2026-03-08: America/Los_Angeles clocks jump from
    /// 01:59:59 PST straight to 03:00:00 PDT — 02:00–02:59 does not exist as
    /// a wall-clock reading that day. PST is UTC−8, PDT is UTC−7; the
    /// transition instant is 2026-03-08T10:00:00Z. An instant just after it,
    /// 2026-03-08T10:30:00Z, is therefore 03:30:00 PDT (10:30 − 7h), and
    /// `secondsOfDay` must read the wall clock's 03:30:00 = 12,600 s — not
    /// some UTC-offset-shifted value a naive fixed-offset conversion could
    /// produce instead.
    ///
    /// `duty(at:)` on the fixture curve (08:00→0.2, 20:00→0.8) at 12,600 s
    /// falls on the wrap segment (12,600 < first.seconds 28,800): elapsed
    /// since the last point (20:00) is 4h to midnight + 3.5h = 7.5h =
    /// 27,000 s of the 12h/43,200 s wrap span, a fraction of 0.625; duty =
    /// 0.8 + (0.2 − 0.8) × 0.625 = 0.425.
    @Test("spring-forward: a wall-clock time after the gap reads as the wall clock, not an offset shift")
    func springForwardGap() {
        let pacific = ScheduleCurve(
            points: [.init(seconds: 28_800, duty: 0.2), .init(seconds: 72_000, duty: 0.8)],
            zoneIdentifier: "America/Los_Angeles"
        )!
        let afterTheGap = utcOn(2026, 3, 8, secondsOfDay: 10 * 3_600 + 30 * 60)  // 10:30:00Z = 03:30:00 PDT
        #expect(pacific.secondsOfDay(for: afterTheGap) == 12_600)
        #expect(abs(pacific.duty(at: afterTheGap) - 0.425) < 1e-9)
    }

    /// US fall-back, 2026-11-01: America/Los_Angeles clocks fall from
    /// 01:59:59 PDT back to 01:00:00 PST — 01:00–01:59 happens twice that
    /// day, once at each offset. The fold instant is 2026-11-01T09:00:00Z
    /// (02:00:00 PDT becomes 01:00:00 PST). Two UTC instants an hour apart —
    /// 08:30:00Z (PDT, UTC−7) and 09:30:00Z (PST, UTC−8) — both read
    /// 01:30:00 on the wall clock (08:30 − 7h = 09:30 − 8h = 01:30), so both
    /// must produce the same `secondsOfDay` = 5,400 s despite being
    /// different absolute instants; a naive fixed-offset conversion would
    /// disagree with itself across the fold instead.
    ///
    /// `duty(at:)` at 5,400 s falls on the wrap segment (5,400 < 28,800):
    /// elapsed since the last point (20:00) is 4h to midnight + 1.5h = 5.5h
    /// = 19,800 s of the 43,200 s span, a fraction of 11/24; duty =
    /// 0.8 + (0.2 − 0.8) × 11/24 = 0.8 − 0.275 = 0.525.
    @Test("fall-back: both occurrences of the repeated wall-clock hour read the same seconds-of-day")
    func fallBackFold() {
        let pacific = ScheduleCurve(
            points: [.init(seconds: 28_800, duty: 0.2), .init(seconds: 72_000, duty: 0.8)],
            zoneIdentifier: "America/Los_Angeles"
        )!
        let firstOneThirty = utcOn(2026, 11, 1, secondsOfDay: 8 * 3_600 + 30 * 60)  // 08:30Z = 01:30 PDT
        let secondOneThirty = utcOn(2026, 11, 1, secondsOfDay: 9 * 3_600 + 30 * 60)  // 09:30Z = 01:30 PST
        #expect(pacific.secondsOfDay(for: firstOneThirty) == 5_400)
        #expect(pacific.secondsOfDay(for: secondOneThirty) == 5_400)
        #expect(abs(pacific.duty(at: firstOneThirty) - 0.525) < 1e-9)
        #expect(abs(pacific.duty(at: secondOneThirty) - 0.525) < 1e-9)
    }

    @Test("plotPoints closes the day: identical synthesized values at 0 and 86400")
    func plotPointsEndpoints() {
        let plotted = curve.plotPoints
        #expect(plotted.first!.seconds == 0)
        #expect(plotted.last!.seconds == 86_400)
        // Midnight is 4h into the 12h wrap from 0.8 to 0.2 → 0.6.
        #expect(abs(plotted.first!.duty - 0.6) < 1e-9)
        // Same maths again, independently, at the other end of the day —
        // not a comparison of the synthesized value to itself.
        #expect(abs(plotted.last!.duty - 0.6) < 1e-9)
        #expect(plotted.count == 4)
    }

    @Test("a first point at second 0 is not duplicated by plotPoints")
    func plotPointsFirstAtMidnight() {
        let flat = ScheduleCurve(
            points: [.init(seconds: 0, duty: 0.1), .init(seconds: 43_200, duty: 0.9)],
            zoneIdentifier: "UTC"
        )!
        #expect(flat.plotPoints.map(\.seconds) == [0, 43_200, 86_400])
        // The first point IS second 0 (duty 0.1, not synthesized); the
        // 86400 endpoint is duty(atSecondsOfDay: 0), computed the same way —
        // 0.1 independently, not a comparison of the two to each other.
        #expect(abs(flat.plotPoints.last!.duty - 0.1) < 1e-9)
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

    /// `86_400` is `plotPoints`' synthesized endpoint, not a legal wire
    /// time. `wireTime(fromSeconds:)` formats it anyway (it does not
    /// validate) but the round trip through `seconds(fromWireTime:)` must
    /// fail — `"24:00:00"` has hour 24, which the parser rejects — so the
    /// asymmetry is explicit rather than `wireTime` silently lying about
    /// what the hub will accept back.
    @Test("wireTime(fromSeconds: 86_400) does not round-trip — it is a plot coordinate, not a wire value")
    func wireTime86400DoesNotRoundTrip() {
        let text = ScheduleCurve.wireTime(fromSeconds: 86_400)
        #expect(text == "24:00:00")
        #expect(ScheduleCurve.seconds(fromWireTime: text) == nil)
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
