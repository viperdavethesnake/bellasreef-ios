// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

/// Finding, 2026-10-02 (coco): the stream's receive loop waited forever on a
/// hub that had gone without closing the socket — power pulled, or the api
/// container frozen with `docker pause` — and the app read "Connected" for 11
/// minutes and never retried. `StreamLiveness` is the half that notices; these
/// pin its timing with a fake ping so no socket is involved.
@Suite("Stream liveness")
struct StreamLivenessTests {

    /// Counts calls from any task.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// A ping that never answers — the hub that went without a close.
    private static let hangingPing: @Sendable () async -> Bool = {
        try? await Task.sleep(for: .seconds(3600))
        return false
    }

    @Test("a pong inside the deadline counts as answered")
    func pongIsAnswered() async {
        #expect(await StreamLiveness.answered(within: .milliseconds(500)) { true })
    }

    @Test("a failed ping is not answered")
    func failedPingIsNotAnswered() async {
        #expect(await StreamLiveness.answered(within: .milliseconds(500)) { false } == false)
    }

    @Test("a ping that never answers gives up at the deadline, not later")
    func hangingPingTimesOut() async {
        let start = ContinuousClock.now
        let answered = await StreamLiveness.answered(within: .milliseconds(50), ping: Self.hangingPing)
        #expect(answered == false)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("an answering hub is never declared silent")
    func answeringHubStaysLive() async {
        let pings = Counter()
        let silent = Counter()
        let watcher = Task {
            await StreamLiveness.watch(
                every: .milliseconds(10), deadline: .milliseconds(200),
                ping: { pings.bump(); return true },
                onSilent: { silent.bump() }
            )
        }
        // Wait for three answered rounds rather than a fixed window: under the
        // full parallel suite a 300 ms window saw only one tick.
        let giveUp = ContinuousClock.now + .seconds(10)
        while pings.count < 3, ContinuousClock.now < giveUp {
            try? await Task.sleep(for: .milliseconds(5))
        }
        watcher.cancel()
        await watcher.value

        #expect(pings.count >= 3)
        #expect(silent.count == 0)
    }

    @Test("an unanswered ping declares the hub silent exactly once and stops")
    func silentHubIsReportedOnce() async {
        let silent = Counter()
        await StreamLiveness.watch(
            every: .milliseconds(10), deadline: .milliseconds(50),
            ping: Self.hangingPing,
            onSilent: { silent.bump() }
        )
        // `watch` returning on its own is the "stops" half.
        #expect(silent.count == 1)
    }

    @Test("cancelling the watch ends it quietly")
    func cancelIsQuiet() async {
        let silent = Counter()
        let watcher = Task {
            await StreamLiveness.watch(
                every: .seconds(60), deadline: .seconds(5),
                ping: { true },
                onSilent: { silent.bump() }
            )
        }
        watcher.cancel()
        await watcher.value
        #expect(silent.count == 0)
    }
}
