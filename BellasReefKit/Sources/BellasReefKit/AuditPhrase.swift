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
public enum AuditPhrase {
    public static func title(action: String?, deviceName: String?) -> String {
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
        case "pair.collected":     return "Pairing request collected"
        case "pair.denied":        return "Denied a pairing request"
        case "pair.no_approver":   return "Pairing attempted with nobody to approve"
        case "pair.code_rejected": return "Wrong setup code entered"
        case "client.revoked":     return "Revoked a device's access"
        case "token.minted":       return "Signed in"
        case "token.rejected":     return "Rejected a sign-in"
        case "override.created":   return "Manual override started"
        case "override.released":  return "Manual override ended"
        default:                   return action
        }
    }
}
