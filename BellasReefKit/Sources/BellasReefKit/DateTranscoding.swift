// Bella's Reef iOS — closed source.

import Foundation
import OpenAPIRuntime

/// ISO-8601 with optional fractional seconds.
///
/// The hub stamps microseconds — `2026-08-10T07:25:56.899163Z` — because it
/// timestamps from Python's `datetime.isoformat()`. The generated client's
/// default transcoder is strict ISO-8601 with **no** fractional part, so every
/// response carrying a timestamp fails to decode with "Expected date string to
/// be ISO8601-formatted".
///
/// This was found the expensive way: the alert banner stayed empty against a
/// hub with a live breach, because `GET /api/v1/alerts` returns `raised_at` and
/// the whole response died on it. The WebSocket path already had its own
/// fractional-seconds decoder, which is exactly why the bug hid — frames
/// decoded, REST did not, and only one of the two was being exercised.
///
/// Both formats are accepted on decode. Encoding always emits fractional
/// seconds, which the hub's Pydantic models parse without complaint.
struct FractionalSecondsDateTranscoder: DateTranscoder {
    /// `ISO8601DateFormatter` is a class with mutable options and is not
    /// `Sendable`, so a shared static instance is a data race under Swift 6.
    /// Building one per call is the honest fix; these are not on a hot path —
    /// a handful of timestamps per REST response, not per frame.
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    func encode(_ date: Date) throws -> String {
        Self.formatter(fractional: true).string(from: date)
    }

    func decode(_ dateString: String) throws -> Date {
        // Fractional first: it is what this hub actually sends, so the common
        // case does not pay for a failed parse.
        if let date = Self.formatter(fractional: true).date(from: dateString) { return date }
        if let date = Self.formatter(fractional: false).date(from: dateString) { return date }
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: [],
                debugDescription: "not an ISO-8601 date: \(dateString)"
            )
        )
    }
}
