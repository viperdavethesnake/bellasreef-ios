// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation

/// The editor's working copy of a schedule, and the one place its validation
/// rules live. `ScheduleEditorView` used to carry these rules itself, in
/// three places that had quietly drifted into three near-identical
/// implementations (`validationText`, `draftCurve`, `save`'s request build) —
/// this type is the single source those three now call through.
public struct ScheduleDraft: Equatable, Sendable {

    /// `validate()`'s failure side — a message to show, and nothing else.
    /// The view reads `.message`; there's no reason for it to construct one
    /// itself, so the synthesized memberwise init (internal, same-module
    /// only, per Swift's usual rule for public structs) is exactly enough.
    public struct Invalid: Error, Equatable, Sendable {
        public let message: String
    }

    /// One row of the draft: a time and a duty text field, kept as text
    /// because the field is mid-edit more often than it holds a legal
    /// number. `ScheduleCurve.Point` is the validated, numeric form this
    /// becomes on success.
    public struct DraftPoint: Equatable, Sendable {
        public var seconds: Int
        public var dutyPercentText: String

        public init(seconds: Int, dutyPercentText: String) {
            self.seconds = seconds
            self.dutyPercentText = dutyPercentText
        }

        /// `nil` for anything that isn't a number 0...100 — an empty field,
        /// stray text, or an out-of-range percentage.
        public var duty: Double? {
            guard let percent = Double(dutyPercentText), (0...100).contains(percent)
            else { return nil }
            return percent / 100
        }
    }

    public var name: String
    public var points: [DraftPoint]
    public var zoneIdentifier: String

    public init(name: String, points: [DraftPoint], zoneIdentifier: String) {
        self.name = name
        self.points = points
        self.zoneIdentifier = zoneIdentifier
    }

    /// The editor's validation, in the exact order and wording the view
    /// used to check inline — a name, then every duty a legal percentage,
    /// then every point's time inside one day, then no two points at the
    /// same time, then at least two points. On success this also does the
    /// wire encoding `save()` used to do by hand: sorted points,
    /// `ScheduleCurve.wireTime`, duty as a 0...1 fraction.
    ///
    /// The time-range check mirrors `ScheduleCurve.init?`'s own
    /// `(0..<86_400).contains($0.seconds)` guard: a point at or past
    /// 86_400 s wire-encodes to `"24:00:00"` or later, which the hub's
    /// `validate_curve` rejects with a 422. Unreachable from the editor
    /// today (`addPoint`/`nextFreeTime` never produce such a point), so
    /// there's no existing UI copy to preserve for it.
    public func validate() -> Result<Components.Schemas.ScheduleRequest, Invalid> {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return .failure(Invalid(message: "The schedule needs a name."))
        }
        if points.contains(where: { $0.duty == nil }) {
            return .failure(Invalid(message: "Brightness is 0–100%."))
        }
        if points.contains(where: { !(0..<86_400).contains($0.seconds) }) {
            return .failure(Invalid(message: "A point's time must be within one day."))
        }
        let times = points.map(\.seconds)
        if Set(times).count != times.count {
            return .failure(Invalid(message: "Two points share a time."))
        }
        if points.count < 2 {
            return .failure(Invalid(message: "A curve needs at least two points."))
        }
        let sorted = points.sorted { $0.seconds < $1.seconds }
        let request = Components.Schemas.ScheduleRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            points: sorted.map {
                .init(at: ScheduleCurve.wireTime(fromSeconds: $0.seconds), duty: $0.duty ?? 0)
            },
            zone: zoneIdentifier
        )
        return .success(request)
    }

    /// The chart preview's rule: a curve from points alone, ignoring the
    /// name — the editor has always shown a preview before a name is typed,
    /// and `validate()` folding every rule into one call must not take that
    /// away. Built the same way `validate()` parses each point's duty, then
    /// handed to `ScheduleCurve`'s own initializer for the rest (ascending
    /// unique times, duty range, a resolvable zone) — no rule text
    /// duplicated here.
    public var curvePreview: ScheduleCurve? {
        let sorted = points.sorted { $0.seconds < $1.seconds }
        let curvePoints = sorted.compactMap { point -> ScheduleCurve.Point? in
            point.duty.map { ScheduleCurve.Point(seconds: point.seconds, duty: $0) }
        }
        guard curvePoints.count == points.count else { return nil }
        return ScheduleCurve(points: curvePoints, zoneIdentifier: zoneIdentifier)
    }

    /// A fixed UTC reference day — `Date(timeIntervalSinceReferenceDate: 0)`,
    /// read in GMT — rather than "today" in the device's zone. The editor's
    /// `DatePicker` only ever contributes an hour and a minute; anchoring
    /// both directions of the conversion to the same zone-less day means the
    /// round trip is identical on every calendar day, including the two
    /// DST-transition days a naive `Calendar.current` anchor would get wrong.
    private static var referenceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// The inverse of `date(secondsOfDay:)` — reads the hour, minute and
    /// second `date` carries in GMT.
    public static func secondsOfDay(from date: Date) -> Int {
        let comps = referenceCalendar.dateComponents([.hour, .minute, .second], from: date)
        return (comps.hour ?? 0) * 3_600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
    }

    /// A `Date` the `DatePicker` can bind to, carrying only `secondsOfDay`'s
    /// hour and minute — the reference day itself is never meaningful, only
    /// the wall-clock time it carries.
    public static func date(secondsOfDay: Int) -> Date {
        let referenceDay = Date(timeIntervalSinceReferenceDate: 0)
        return referenceCalendar.date(
            bySettingHour: secondsOfDay / 3_600,
            minute: secondsOfDay % 3_600 / 60,
            second: secondsOfDay % 60,
            of: referenceCalendar.startOfDay(for: referenceDay)
        ) ?? referenceDay
    }

    /// `addPoint`'s rule: an hour after the latest point, capped just short
    /// of midnight so a new point never lands past 86_340 s (23:59). If that
    /// minute is already taken, the nearest free minute at or below the cap
    /// — never above it, since the cap is already the furthest a new point
    /// is allowed to go. `nil` only when every minute from the cap down to
    /// midnight is taken, which the Add control reads as "disabled."
    public func nextFreeTime() -> Int? {
        let taken = Set(points.map(\.seconds))
        let latest = points.map(\.seconds).max() ?? 0
        let target = min(latest + 3_600, 86_340)
        if !taken.contains(target) { return target }
        var candidate = target - 60
        while candidate >= 0 {
            if !taken.contains(candidate) { return candidate }
            candidate -= 60
        }
        return nil
    }
}
