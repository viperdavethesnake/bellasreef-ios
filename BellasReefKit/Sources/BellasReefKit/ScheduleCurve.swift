// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation

/// A schedule's curve as pure maths: the engine's `duty_at`
/// (`profiles.py`, contracts §time-and-scheduling) ported so that what this
/// app draws and predicts is what the hub will actually emit. Linear between
/// ascending points; the segment from the last point back to the first
/// interpolates *through* midnight — a flat treatment would put a step at
/// exactly the darkest hour, where it is least wanted and most visible.
public struct ScheduleCurve: Equatable, Hashable, Sendable {

    public struct Point: Equatable, Hashable, Sendable {
        public let seconds: Int
        public let duty: Double

        public init(seconds: Int, duty: Double) {
            self.seconds = seconds
            self.duty = duty
        }
    }

    public let points: [Point]
    public let zone: TimeZone

    /// The hub's own `validate_curve` rules, applied at construction: at
    /// least two points, strictly ascending unique times inside one day,
    /// duty within 0...1, and a zone the platform can resolve. A curve that
    /// fails them renders as absent rather than as a guess.
    public init?(points: [Point], zoneIdentifier: String) {
        guard points.count >= 2,
              let zone = TimeZone(identifier: zoneIdentifier),
              points.allSatisfy({ (0..<86_400).contains($0.seconds) && (0.0...1.0).contains($0.duty) }),
              zip(points, points.dropFirst()).allSatisfy({ $0.seconds < $1.seconds })
        else { return nil }
        self.points = points
        self.zone = zone
    }

    public init?(_ schedule: Components.Schemas.ScheduleView) {
        let parsed = schedule.points.compactMap { point -> Point? in
            guard let seconds = Self.seconds(fromWireTime: point.at) else { return nil }
            return Point(seconds: seconds, duty: point.duty)
        }
        guard parsed.count == schedule.points.count else { return nil }
        self.init(points: parsed, zoneIdentifier: schedule.zone)
    }

    /// Interpolated duty for `instant`, converted into the schedule's zone
    /// first — same contract as the engine's, so the caller can stay in the
    /// device's clock.
    public func duty(at instant: Date) -> Double {
        duty(atSecondsOfDay: secondsOfDay(for: instant))
    }

    /// Seconds since local midnight in the *schedule's* zone — the x-position
    /// of "now" on any drawing of this curve.
    public func secondsOfDay(for instant: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let comps = calendar.dateComponents([.hour, .minute, .second], from: instant)
        return (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
    }

    /// The next anchor the curve will reach after `instant`, wrapping past
    /// midnight — "35 % at 19:00" on the light detail screen. Always exists:
    /// a curve has at least two points.
    public func nextPoint(after instant: Date) -> Point {
        let now = secondsOfDay(for: instant)
        return points.first { $0.seconds > now } ?? points[0]
    }

    /// The curve as drawn midnight-to-midnight: the real points, plus
    /// synthesized endpoints at 0 and 86400 carrying the wrap segment's
    /// value there, so the plotted line spans the whole day and its two ends
    /// meet at the same duty.
    public var plotPoints: [Point] {
        let atMidnight = duty(atSecondsOfDay: 0)
        var plotted = points
        if points[0].seconds != 0 {
            plotted.insert(Point(seconds: 0, duty: atMidnight), at: 0)
        }
        plotted.append(Point(seconds: 86_400, duty: atMidnight))
        return plotted
    }

    /// Duty at a bare seconds-of-day — for callers that already computed
    /// "now" in the schedule's zone (the card computes it once and uses it
    /// for both the dot's x and this label).
    public func duty(atSecondsToday seconds: Int) -> Double {
        duty(atSecondsOfDay: seconds)
    }

    private func duty(atSecondsOfDay now: Int) -> Double {
        let first = points[0], last = points[points.count - 1]
        if now < first.seconds || now >= last.seconds {
            let span = (first.seconds + 86_400) - last.seconds
            guard span != 0 else { return last.duty }
            // Swift's % is remainder (sign-preserving); Python's is modulo.
            // The backend writes `(now - last) % 86400` and relies on the
            // modulo; matching it needs the double-% normalisation here.
            let elapsed = ((now - last.seconds) % 86_400 + 86_400) % 86_400
            return Self.lerp(last.duty, first.duty, Double(elapsed) / Double(span))
        }
        for (lo, hi) in zip(points, points.dropFirst()) where lo.seconds <= now && now < hi.seconds {
            let span = hi.seconds - lo.seconds
            return Self.lerp(lo.duty, hi.duty, Double(now - lo.seconds) / Double(span))
        }
        return last.duty
    }

    /// Endpoint-guarded, exactly like the engine's `_lerp`: a duty of
    /// 1.0000000000000002 would fail the wire contract's `le=1.0` on the
    /// next PUT, taking a channel out on a rounding error.
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        min(1.0, max(0.0, a + (b - a) * t))
    }

    /// "HH:MM:SS" (the wire form Pydantic emits) or "HH:MM" → seconds of
    /// day. Strict otherwise: a malformed time is nil, not a guess.
    public static func seconds(fromWireTime text: String) -> Int? {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count) else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == fields.count else { return nil }
        let hour = numbers[0], minute = numbers[1]
        let second = numbers.count == 3 ? numbers[2] : 0
        guard (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second)
        else { return nil }
        return hour * 3600 + minute * 60 + second
    }

    public static func wireTime(fromSeconds seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }
}
