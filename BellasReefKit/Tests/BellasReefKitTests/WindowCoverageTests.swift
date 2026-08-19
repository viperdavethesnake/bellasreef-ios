// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation
import Testing

@testable import BellasReefKit

/// UX review B6: 7D with one day of data drew six days of empty axis with no
/// word about why. The axis stays the picked window (clamping would make 7D
/// stop meaning 7D); the caption says where the record starts.
@Suite("Window coverage caption")
struct WindowCoverageTests {
    private let day: TimeInterval = 86_400
    private let end = ISO8601DateFormatter().date(from: "2026-08-18T20:00:00Z")!
    private let tz = TimeZone(identifier: "UTC")!

    @Test("data covering most of the window says nothing")
    func covered() {
        let window = end.addingTimeInterval(-7 * day)...end
        #expect(WindowCoverage.caption(window: window, firstDataAt: end.addingTimeInterval(-6 * day), timeZone: tz) == nil)
    }

    @Test("data covering under half the window names its start")
    func sparse() {
        let window = end.addingTimeInterval(-7 * day)...end
        let first = end.addingTimeInterval(-1 * day)
        #expect(WindowCoverage.caption(window: window, firstDataAt: first, timeZone: tz)
                == "The record starts 17 Aug — about 1 day of the 7 shown.")
    }

    @Test("no data at all is the empty state's job, not this caption's")
    func none() {
        let window = end.addingTimeInterval(-7 * day)...end
        #expect(WindowCoverage.caption(window: window, firstDataAt: nil, timeZone: tz) == nil)
    }

    @Test("a short window counts in hours")
    func hours() {
        let window = end.addingTimeInterval(-6 * 3600)...end
        let first = end.addingTimeInterval(-2 * 3600)
        #expect(WindowCoverage.caption(window: window, firstDataAt: first, timeZone: tz)
                == "The record starts 18:00 — about 2 hours of the 6 shown.")
    }
}
