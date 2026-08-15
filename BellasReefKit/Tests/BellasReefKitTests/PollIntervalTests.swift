// Bella's Reef iOS — closed source.

import Testing

@testable import BellasReefKit

@Suite("Poll interval")
struct PollIntervalTests {

    @Test("the floor is 2 seconds — one probe's read cost alone is 831 ms")
    func floorIsTwoSeconds() {
        #expect(PollInterval.isValid("1") == false)
        #expect(PollInterval.isValid("2") == true)
    }

    @Test("non-numeric input is invalid, not just out of range")
    func nonNumericIsInvalid() {
        #expect(PollInterval.isValid("") == false)
        #expect(PollInterval.isValid("five") == false)
    }
}
