// Bella's Reef iOS — closed source.

import Testing

@testable import BellasReefKit

@Suite("Alerting tier")
struct AlertingTierTests {

    @Test("statement is the exact two sentences ruled on 2026-09-02")
    func statementIsExact() {
        #expect(
            AlertingTier.statement
                == "Alerts reach you only while the app is open. This hub doesn't send push."
        )
    }
}
