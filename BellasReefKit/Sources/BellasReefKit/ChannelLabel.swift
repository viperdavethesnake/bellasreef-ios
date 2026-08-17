// Bella's Reef iOS — closed source.

/// How a channel is written where a person reads it.
///
/// Ruled 2026-08-17: channels are shown 1-based. Hardware and the wire stay
/// 0-based — `capability.channel` is "0".."15" on a PCA9685 and "0".."3" on
/// the RP1, bindings and driver registers are unchanged — so this is a
/// display transform and nothing else. Anything that goes back to the hub
/// sends the raw string.
///
/// A channel is not always a number: a 1-Wire probe's channel is its ROM
/// (`28-000000bfe244`), which is an identity, not an index, and is shown
/// exactly as the hub said it.
public enum ChannelLabel {

    /// `channel` as the operator should read it: a whole non-negative number
    /// shifted up by one, anything else returned untouched.
    public static func humanNumber(_ channel: String) -> String {
        // `Int.max` cannot be shifted up, so it falls through as itself rather
        // than trapping. No such channel exists, but a crash on a malformed
        // hub string is a worse answer than showing the string.
        guard let index = Int(channel), index >= 0, index < Int.max else { return channel }
        return String(index + 1)
    }
}
