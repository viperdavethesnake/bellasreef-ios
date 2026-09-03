// Bella's Reef iOS — closed source.

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
}
