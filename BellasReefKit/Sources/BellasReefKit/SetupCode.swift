// Bella's Reef iOS — closed source.

/// The setup-code alphabet and grouping, mirrored from the hub.
///
/// Feature 1 of the 2026-08-15 new-owner-experience spec: 8 characters from a
/// confusable-free alphabet, displayed grouped as `7KF2-9QMD`. Case is
/// insensitive on entry and the grouping dash is cosmetic — the hub strips
/// both before comparing, so this mirror has to agree exactly or a code that
/// is right reads as wrong.
public enum SetupCode {

    /// What the hub actually compares: uppercase, letters and digits only.
    /// Whitespace and the cosmetic dash both fall out of the same filter.
    public static func normalize(_ entry: String) -> String {
        entry.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// `7KF2-9QMD` as you type — no dash until the second group has started,
    /// so `display("7KF")` is `"7KF"` rather than a trailing `"7KF-"`.
    public static func display(_ entry: String) -> String {
        let raw = normalize(entry)
        guard raw.count > 4 else { return raw }
        return "\(raw.prefix(4))-\(raw.dropFirst(4).prefix(4))"
    }
}
