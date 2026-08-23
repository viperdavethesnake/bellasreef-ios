// Bella's Reef iOS — closed source.

/// Verbs for the audit log. An audit row used to render `actor · subject`,
/// and `subject` was always `bellasreef.audit.auth` — three identical tokens
/// per row, the one event that mattered (an unadopt) invisible among them.
/// `AuditPhrase` turns the typed `action` the backend now sends into a
/// sentence a person reads at a glance.
///
/// Amended by a controller ruling after the backend renamed its pairing
/// events: `client.paired` never ships (the backend never emits it) and is
/// replaced by the four outcomes a pairing attempt can actually grant —
/// `pair.window_used`, `pair.approved`, `pair.tofu_granted`,
/// `pair.code_granted`.
///
/// Unknown actions fall back to their own raw name rather than a blank or
/// generic string, so a future backend event ships legible on day one with
/// no client change required.
///
/// UX review SF7: the five `schedule.*` events fell through to that raw-name
/// default (`"schedule.created"` on screen, not a sentence) because they
/// shipped after this switch was last extended. `deviceName` here is the
/// schedule's own name for the three CRUD verbs, and the assigned channel's
/// display name for assign/unassign.
public enum AuditPhrase {
    /// `reason` is what the backend put on `override.released` since the E1
    /// fix (2026-08-18): `manual`, `superseded`, `expired`, `lapsed`. Before
    /// that every ending was "Manual override ended" and most endings were
    /// never written at all (UX review A9).
    public static func title(action: String?, deviceName: String?, reason: String? = nil) -> String {
        guard let action else { return "Event recorded" }
        let name = deviceName
        switch action {
        case "device.bound":       return "Adopted \(name ?? "a device")"
        case "device.unbound":     return "Unadopted \(name ?? "a device")"
        case "device.forgotten":   return "Cleared \(name ?? "a device")"
        case "device.renamed":     return "Renamed \(name ?? "a device")"
        case "thresholds.set":     return "Set alerts for \(name ?? "a device")"
        case "pair.window_used":   return "Paired a device"
        case "pair.approved":      return "Approved a pairing"
        case "pair.tofu_granted":  return "Paired the first device"
        case "pair.code_granted":  return "Paired with the setup code"
        case "pair.requested":     return "Asked to pair"
        case "pair.window_opened": return "Opened a pairing window"
        case "pair.collected":     return "Pairing request collected"
        case "pair.denied":        return "Denied a pairing request"
        case "pair.no_approver":   return "Pairing attempted with nobody to approve"
        case "pair.code_rejected": return "Wrong setup code entered"
        case "client.revoked":     return "Revoked a device's access"
        case "token.minted":       return "Signed in"
        case "token.rejected":     return "Rejected a sign-in"
        case "schedule.created":    return name.map { "Created schedule \($0)" } ?? "Created a schedule"
        case "schedule.updated":    return name.map { "Edited schedule \($0)" } ?? "Edited a schedule"
        case "schedule.deleted":    return name.map { "Deleted schedule \($0)" } ?? "Deleted a schedule"
        case "schedule.assigned":   return "Schedule assigned\(name.map { " to \($0)" } ?? "")"
        case "schedule.unassigned": return "Schedule unassigned\(name.map { " from \($0)" } ?? "")"
        case "override.created":   return "Hold\(name.map { " on \($0)" } ?? "") started"
        case "override.released":
            let on = name.map { " on \($0)" } ?? ""
            switch reason {
            case "manual":     return "Hold\(on) released"
            case "superseded": return "Hold\(on) ended — replaced by a new hold"
            case "expired":    return "Hold\(on) ended — time ran out"
            case "lapsed":     return "Hold\(on) ended — lapsed while the hub was down"
            default:           return "Hold\(on) ended"
            }
        default:                   return action
        }
    }
}
