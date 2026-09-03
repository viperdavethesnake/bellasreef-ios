// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

/// UX review D2: the Live Activity for a hold has to come down when the hold
/// ends, including the two endings this process never sees — expiry on the
/// hub, and a release from another client. Nothing in ActivityKit runs in
/// this suite, so the set arithmetic that decides it is what gets tested.
@Suite("Hold activity reconcile")
struct HoldActivityReconcileTests {

    @Test("a hold the frames still carry is left alone")
    func stillHeld() {
        #expect(
            HoldActivityReconcile.endedIds(started: ["ov-1"], present: ["ov-1"]) == []
        )
    }

    @Test("a hold the frames no longer carry has ended")
    func expiredOrReleasedElsewhere() {
        #expect(
            HoldActivityReconcile.endedIds(started: ["ov-1"], present: []) == ["ov-1"]
        )
    }

    @Test("only the missing ones end, not the whole set")
    func partialOverlap() {
        #expect(
            HoldActivityReconcile.endedIds(
                started: ["ov-1", "ov-2", "ov-3"], present: ["ov-2", "ov-9"]
            ) == ["ov-1", "ov-3"]
        )
    }

    /// A re-hold supersedes on the backend and gets a *new* override id, so
    /// the frame carrying `ov-2` where this client started `ov-1` is not "the
    /// same hold, renamed" — the old banner is stale and must go.
    @Test("a superseding re-hold ends the banner for the id it replaced")
    func reheldUnderANewId() {
        #expect(
            HoldActivityReconcile.endedIds(started: ["ov-1"], present: ["ov-2"]) == ["ov-1"]
        )
    }

    /// Someone else's hold is not this client's banner to raise. The
    /// difference runs one way on purpose.
    @Test("a hold this client never started is not adopted")
    func anotherClientsHoldIsIgnored() {
        #expect(
            HoldActivityReconcile.endedIds(started: [], present: ["ov-7"]) == []
        )
    }

    @Test("nothing started, nothing ends")
    func empty() {
        #expect(HoldActivityReconcile.endedIds(started: [], present: []) == [])
    }

    // MARK: Eligibility — which activities may be judged at all

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the grace window is thirty seconds")
    func graceIsThirtySeconds() {
        #expect(HoldActivityReconcile.reconcileGrace == 30)
    }

    @Test("an activity younger than the grace window is not judged")
    func insideTheGrace() {
        #expect(
            HoldActivityReconcile.eligible(
                startedAt: Self.t0, now: Self.t0, sawStateFrame: true
            ) == false
        )
        #expect(
            HoldActivityReconcile.eligible(
                startedAt: Self.t0, now: Self.t0.addingTimeInterval(29.9), sawStateFrame: true
            ) == false
        )
    }

    /// The boundary itself is eligible. Named because "is it >= or >" is
    /// exactly the kind of thing a later edit flips.
    @Test("at exactly the grace window it is judged")
    func atTheBoundary() {
        #expect(
            HoldActivityReconcile.eligible(
                startedAt: Self.t0, now: Self.t0.addingTimeInterval(30), sawStateFrame: true
            )
        )
    }

    @Test("past the grace window it is judged")
    func pastTheGrace() {
        #expect(
            HoldActivityReconcile.eligible(
                startedAt: Self.t0, now: Self.t0.addingTimeInterval(3600), sawStateFrame: true
            )
        )
    }

    /// The bug this gate exists for: the stream emits `.ready` and `.sensor`
    /// frames before any actuator has spoken, so an activity adopted at
    /// launch on a slow socket would be judged against an empty live-hold
    /// set and its banner ended while the light is still held.
    @Test("no state frame yet means nothing is judged, however old")
    func noStateFrameBlocksEverything() {
        #expect(
            HoldActivityReconcile.eligible(
                startedAt: Self.t0, now: Self.t0.addingTimeInterval(86_400), sawStateFrame: false
            ) == false
        )
        #expect(
            HoldActivityReconcile.eligible(
                startedAt: .distantPast, now: Self.t0, sawStateFrame: false
            ) == false
        )
    }

    @Test("the grace window can be overridden by a caller that needs a different one")
    func customGrace() {
        #expect(
            HoldActivityReconcile.eligible(
                startedAt: Self.t0, now: Self.t0.addingTimeInterval(5), sawStateFrame: true,
                grace: 1
            )
        )
    }
}
