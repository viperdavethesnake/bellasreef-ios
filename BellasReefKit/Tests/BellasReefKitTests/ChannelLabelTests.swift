// Bella's Reef iOS — closed source.

import Testing

@testable import BellasReefKit

@Suite("Channel label")
struct ChannelLabelTests {

    @Test("a numeric channel reads one higher than the wire carries it")
    func numericChannelsShiftUp() {
        #expect(ChannelLabel.humanNumber("0") == "1")
        #expect(ChannelLabel.humanNumber("3") == "4")
        #expect(ChannelLabel.humanNumber("15") == "16")
    }

    @Test("a 1-Wire ROM is an identity, not an index, and is shown as given")
    func romsAreUntouched() {
        #expect(ChannelLabel.humanNumber("28-000000bfe244") == "28-000000bfe244")
    }

    @Test("anything that is not a whole non-negative number is passed through")
    func nonNumbersArePassedThrough() {
        #expect(ChannelLabel.humanNumber("") == "")
        #expect(ChannelLabel.humanNumber("-1") == "-1")
        #expect(ChannelLabel.humanNumber("1.5") == "1.5")
        #expect(ChannelLabel.humanNumber("ch0") == "ch0")
    }
}
