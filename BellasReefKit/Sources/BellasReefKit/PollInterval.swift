// Bella's Reef iOS — closed source.

/// The floor for a sensor's poll cadence.
///
/// Measured on target hardware: a DS18B20 read costs 831 ms on the serialized
/// 1-Wire bus (CLAUDE.md, backend repo). A 1 s poll barely fits one probe and
/// two probes exceed it outright, so this is the driver-interface timing rule
/// enforced at the point of entry rather than left for the hub to reject.
public enum PollInterval {

    /// Below this, a poll cannot outrun the read it is scheduling.
    public static let minimumSeconds = 2

    /// `text` is what the operator typed. Valid means: parses as a whole
    /// number of seconds, at or above the floor.
    public static func isValid(_ text: String) -> Bool {
        guard let seconds = Int(text.trimmingCharacters(in: .whitespaces)) else { return false }
        return seconds >= minimumSeconds
    }
}
