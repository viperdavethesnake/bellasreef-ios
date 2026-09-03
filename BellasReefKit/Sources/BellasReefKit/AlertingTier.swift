// Bella's Reef iOS — closed source.

/// What tier of alerting this app actually offers, said plainly.
///
/// David's ruling, 2026-09-02 (D1, option 2): the app states the tier it is
/// at now rather than implying a push-notification safety net that does not
/// exist. This build is LAN-only, foreground-only — alerts are a banner on
/// the Tank tab while the app is open and nothing else. APNs (a background,
/// server-pushed tier) is a project of its own, gated on the hub having
/// something to push from, and is not this.
public enum AlertingTier {
    /// The exact wording ruled on 2026-09-02. Kept as one constant so a copy
    /// edit is a diffed decision, not a drive-by string change buried in a
    /// view.
    public static let statement = "Alerts reach you only while the app is open. This hub doesn't send push."
}
