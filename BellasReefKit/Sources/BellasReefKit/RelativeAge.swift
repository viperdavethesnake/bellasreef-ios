// Bella's Reef iOS — closed source.

import Foundation

/// How long ago something happened, phrased for a status line.
///
/// Replaces `Text(date, format: .relative(presentation: .numeric))` on the
/// alert banner, which renders a *just*-raised breach as "in 0 seconds" —
/// future tense for something that has already happened, at the exact moment
/// the operator is most likely to be reading it.
///
/// Two rules, both from design brief §7.7:
///
/// * Zero age reads "just now", not "0 seconds ago" and never "in …".
/// * Time is only ever counted *up*. A timestamp slightly in the future — the
///   hub's clock is NTP-corrected and can step, and this device's need not
///   agree — is clamped to zero rather than phrased as a countdown. A tank
///   alert that says "in 3 seconds" reads as a prediction.
public enum RelativeAge {

    public static func describe(from moment: Date, now: Date = Date()) -> String {
        // Clamped, not `abs()`: a future timestamp is an unknown-size clock
        // disagreement, and reporting it as elapsed time would invent a number.
        let seconds = Int(max(0, now.timeIntervalSince(moment)))

        switch seconds {
        case 0..<5: return "just now"
        case 5..<60: return "\(seconds)s ago"
        case 60..<3600: return "\(seconds / 60)m ago"
        case 3600..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}
