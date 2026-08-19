// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

/// UX review B4: a drag across a History chart reads out the bucket under the
/// finger. Which bucket that is must be a pure decision — nearest by time,
/// and only within one bucket step, so a finger in a gap gets no bucket
/// rather than the nearest one across the hole. A gap is a gap.
@Suite("History scrub — bucket under the finger")
struct HistoryScrubTests {
    private let step: TimeInterval = 60
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func bucket(_ minutes: Double, avg: Double = 25) -> Components.Schemas.HistoryBucket {
        Components.Schemas.HistoryBucket(
            at: t0.addingTimeInterval(minutes * 60), average: avg, maximum: avg + 0.5, minimum: avg - 0.5
        )
    }

    /// Two runs of three buckets with a five-minute hole between them: minutes
    /// 0,1,2 and 8,9,10.
    private var torn: [HistorySegment] {
        [
            HistorySegment(id: 0, buckets: [bucket(0, avg: 20), bucket(1, avg: 21), bucket(2, avg: 22)]),
            HistorySegment(id: 1, buckets: [bucket(8, avg: 28), bucket(9, avg: 29), bucket(10, avg: 30)]),
        ]
    }

    @Test("a finger on a bucket gets that bucket")
    func exact() {
        let hit = HistoryScrub.bucket(at: t0.addingTimeInterval(60), in: torn, step: step)
        #expect(hit?.average == 21)
    }

    @Test("between two buckets, the nearer one wins")
    func nearest() {
        let hit = HistoryScrub.bucket(at: t0.addingTimeInterval(100), in: torn, step: step)
        #expect(hit?.average == 22)
    }

    @Test("the middle of a gap is nobody's bucket")
    func gapIsNil() {
        // Minute 5: three minutes from either edge, well past one step.
        #expect(HistoryScrub.bucket(at: t0.addingTimeInterval(5 * 60), in: torn, step: step) == nil)
    }

    @Test("just inside a step of a gap's edge still reads the edge bucket")
    func gapEdge() {
        // 2:40 is 40 s past the last bucket of the first run — within one step.
        let hit = HistoryScrub.bucket(at: t0.addingTimeInterval(160), in: torn, step: step)
        #expect(hit?.average == 22)
        // 7:20 is 40 s before the first bucket of the second run.
        let after = HistoryScrub.bucket(at: t0.addingTimeInterval(440), in: torn, step: step)
        #expect(after?.average == 28)
    }

    @Test("past the last bucket by more than a step is no bucket — the record ends")
    func trailingEdge() {
        #expect(HistoryScrub.bucket(at: t0.addingTimeInterval(11 * 60 + 1), in: torn, step: step) == nil)
        #expect(HistoryScrub.bucket(at: t0.addingTimeInterval(-61), in: torn, step: step) == nil)
    }

    @Test("no segments, no bucket")
    func empty() {
        #expect(HistoryScrub.bucket(at: t0, in: [], step: step) == nil)
    }
}

/// The readout's numbers, in the unit the axis already shows.
@Suite("History scrub — value label")
struct HistoryScrubLabelTests {
    private let en = Locale(identifier: "en_US")

    @Test("temperature keeps the one decimal the probe can support")
    func temperature() {
        #expect(HistoryScrub.label(78.14, unit: "°F", locale: en) == "78.1°F")
        #expect(HistoryScrub.label(25, unit: "°C", locale: en) == "25.0°C")
    }

    @Test("duty is whole percent")
    func duty() {
        #expect(HistoryScrub.label(42.4, unit: "%", locale: en) == "42%")
        #expect(HistoryScrub.label(0, unit: "%", locale: en) == "0%")
    }
}
