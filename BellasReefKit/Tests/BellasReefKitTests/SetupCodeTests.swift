// Bella's Reef iOS — closed source.

import Testing

@testable import BellasReefKit

@Suite("Setup code")
struct SetupCodeTests {

    @Test("normalize mirrors the backend: uppercase, dashes and spaces stripped")
    func normalizeMirrorsTheBackend() {
        #expect(SetupCode.normalize("7kf2-9qmd") == "7KF29QMD")
        #expect(SetupCode.normalize(" 7KF2 9QMD ") == "7KF29QMD")
    }

    @Test("display groups 4-4, but only once the second group has started")
    func displayGroupsFourFour() {
        #expect(SetupCode.display("7KF29QMD") == "7KF2-9QMD")
        // No dash until it earns one.
        #expect(SetupCode.display("7KF") == "7KF")
    }
}
