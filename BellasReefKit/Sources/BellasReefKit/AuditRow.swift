// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation

/// The three lines of an audit row, as facts a person can use afterwards.
///
/// UX review A8: the log showed a raw client UUID as each row's identity,
/// "1h ago" on six rows with no way to order them, and `api` as the actor of
/// everything. A post-mortem needs *which device*, *who*, and *when* — in
/// that order of importance.
public enum AuditRow {
    /// The device an event is about: the row's `device_id` when the writer
    /// set one, else the payload's `target` (override events name their
    /// target rather than an `actuator_id`, so the writer leaves `device_id`
    /// null for them).
    public static func subjectId(deviceId: String?, payload: [String: (any Sendable)?]) -> String? {
        if let deviceId { return deviceId }
        if let target = payload["target"] as? String { return target }
        return nil
    }

    /// Who did it. A paired client's id becomes its name; the hub's own
    /// services keep short honest labels; an id nobody recognises is shortened
    /// rather than dumped whole.
    public static func actorName(_ actor: String, clients: [String: String]) -> String {
        if let name = clients[actor] { return name }
        switch actor {
        case "api": return "hub"
        case "control-engine": return "engine"
        case "bellasreef-cli": return "hub CLI"
        case "hardware-io": return "hardware"
        default:
            if UUID(uuidString: actor) != nil { return "client \(actor.prefix(8))" }
            return actor
        }
    }

    /// A clock time first, the relative age second. The log is the one place
    /// recency is not the point; six rows reading "1h ago" have no order.
    /// Older than today carries the date.
    public static func when(_ moment: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = DateFormatter()
        time.timeZone = timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = calendar.isDate(moment, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        return "\(time.string(from: moment)) · \(RelativeAge.describe(from: moment, now: now))"
    }
}
