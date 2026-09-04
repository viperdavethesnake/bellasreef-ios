// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

@Suite("Relative age")
struct RelativeAgeTests {
    let now = Date(timeIntervalSince1970: 1_786_400_000)

    @Test("a breach raised this instant reads as now, not 'in 0 seconds'")
    func zeroAge() {
        #expect(RelativeAge.describe(from: now, now: now) == "just now")
    }

    @Test("a timestamp slightly in the future is never phrased as a countdown")
    func futureIsClamped() {
        // The hub's clock is NTP-corrected and can step; this device's need not
        // agree. A tank alert reading "in 3 seconds" is a prediction.
        let ahead = now.addingTimeInterval(3)
        #expect(RelativeAge.describe(from: ahead, now: now) == "just now")
    }

    @Test("seconds, minutes, hours and days count up")
    func countsUp() {
        #expect(RelativeAge.describe(from: now.addingTimeInterval(-30), now: now) == "30s ago")
        #expect(RelativeAge.describe(from: now.addingTimeInterval(-120), now: now) == "2m ago")
        #expect(RelativeAge.describe(from: now.addingTimeInterval(-7200), now: now) == "2h ago")
        #expect(RelativeAge.describe(from: now.addingTimeInterval(-172_800), now: now) == "2d ago")
    }

    @Test("nothing is ever phrased in the future")
    func neverFuture() {
        for offset in stride(from: -600.0, through: 600.0, by: 37.0) {
            let said = RelativeAge.describe(from: now.addingTimeInterval(offset), now: now)
            #expect(!said.hasPrefix("in "), "\(said) is future-phrased")
        }
    }

    @Test("the contracted form drops the tense and nothing else")
    func compactUnits() {
        // "Hub unreachable · 4m" — the strip's own words carry the tense.
        #expect(RelativeAge.compact(from: now, now: now) == "0s")
        #expect(RelativeAge.compact(from: now.addingTimeInterval(-30), now: now) == "30s")
        #expect(RelativeAge.compact(from: now.addingTimeInterval(-260), now: now) == "4m")
        #expect(RelativeAge.compact(from: now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(RelativeAge.compact(from: now.addingTimeInterval(-172_800), now: now) == "2d")
    }

    @Test("the contracted form clamps the future too")
    func compactFutureIsClamped() {
        #expect(RelativeAge.compact(from: now.addingTimeInterval(3), now: now) == "0s")
    }
}
