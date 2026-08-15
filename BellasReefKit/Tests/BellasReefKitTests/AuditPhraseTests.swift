// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

/// Task 4 brief, amended by a controller ruling: the backend renamed its
/// pairing events after the plan was written. `client.paired` is gone —
/// the backend never emits it — replaced by the four `pair.*_granted`/
/// `pair.window_used` outcomes a pairing can actually resolve to.
@Suite("AuditPhrase")
struct AuditPhraseTests {

    @Test("known actions read as verbs")
    func knownActionsReadAsVerbs() {
        #expect(AuditPhrase.title(action: "device.unbound", deviceName: "Pretty Blue")
                == "Unadopted Pretty Blue")
        #expect(AuditPhrase.title(action: "device.bound", deviceName: "Pretty Blue")
                == "Adopted Pretty Blue")
        #expect(AuditPhrase.title(action: "device.forgotten", deviceName: "Pretty Blue")
                == "Cleared Pretty Blue")
        #expect(AuditPhrase.title(action: "device.renamed", deviceName: "Pretty Blue")
                == "Renamed Pretty Blue")
        #expect(AuditPhrase.title(action: "thresholds.set", deviceName: "Pretty Blue")
                == "Set alerts for Pretty Blue")
        #expect(AuditPhrase.title(action: "client.revoked", deviceName: nil)
                == "Revoked a device's access")
        #expect(AuditPhrase.title(action: "token.minted", deviceName: nil)
                == "Signed in")
        #expect(AuditPhrase.title(action: "token.rejected", deviceName: nil)
                == "Rejected a sign-in")
        #expect(AuditPhrase.title(action: "override.created", deviceName: nil)
                == "Manual override started")
        #expect(AuditPhrase.title(action: "override.released", deviceName: nil)
                == "Manual override ended")
    }

    /// The four ways a pairing attempt can grant or use access. Each reads as
    /// its own sentence rather than collapsing into one generic "paired".
    @Test("pairing grant actions read as distinct verbs")
    func pairingGrantActionsReadAsDistinctVerbs() {
        #expect(AuditPhrase.title(action: "pair.window_used", deviceName: nil)
                == "Paired a device")
        #expect(AuditPhrase.title(action: "pair.approved", deviceName: nil)
                == "Approved a pairing")
        #expect(AuditPhrase.title(action: "pair.tofu_granted", deviceName: nil)
                == "Paired the first device")
        #expect(AuditPhrase.title(action: "pair.code_granted", deviceName: nil)
                == "Paired with the setup code")
    }

    @Test("pairing failure and near-miss actions read as sentences")
    func pairingFailureActionsReadAsSentences() {
        #expect(AuditPhrase.title(action: "pair.collected", deviceName: nil)
                == "Pairing request collected")
        #expect(AuditPhrase.title(action: "pair.denied", deviceName: nil)
                == "Denied a pairing request")
        #expect(AuditPhrase.title(action: "pair.no_approver", deviceName: nil)
                == "Pairing attempted with nobody to approve")
        #expect(AuditPhrase.title(action: "pair.code_rejected", deviceName: nil)
                == "Wrong setup code entered")
    }

    @Test("a device-scoped action with no known name falls back to 'a device'")
    func deviceActionWithNoNameFallsBack() {
        #expect(AuditPhrase.title(action: "device.bound", deviceName: nil)
                == "Adopted a device")
    }

    @Test("an unknown action falls back to its own raw name")
    func unknownActionFallsBackToItself() {
        #expect(AuditPhrase.title(action: "future.event", deviceName: nil)
                == "future.event")
    }

    @Test("a missing action says 'Event recorded'")
    func missingActionSaysRecorded() {
        #expect(AuditPhrase.title(action: nil, deviceName: nil) == "Event recorded")
    }
}
