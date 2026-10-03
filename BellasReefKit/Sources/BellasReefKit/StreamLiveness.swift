// Bella's Reef iOS — closed source.

import Foundation

/// Whether the hub behind an open stream socket is still answering.
///
/// A socket only reports its own end when the far side closes it. A hub whose
/// power is pulled, or whose api is frozen (`docker pause`), sends no close —
/// and `URLSessionWebSocketTask.receive()` then waits forever. Found on coco
/// 2026-10-02: the app read "Connected" for 11 minutes after the hub went,
/// and never retried, because nothing ever threw. The hub already pings us
/// (uvicorn, every 20 s), but URLSession answers those itself and never tells
/// the app, so the client has to ask on its own.
///
/// Kept apart from `StreamClient` so the timing can be tested with a fake ping.
enum StreamLiveness {
    /// How often an open stream is asked to prove itself.
    static let interval: Duration = .seconds(10)
    /// How long a pong may take before the hub counts as gone. Worst case to
    /// notice: `interval + deadline`, 15 s.
    static let deadline: Duration = .seconds(5)

    /// True when `ping` answers `true` within `deadline`.
    ///
    /// Returns at the deadline even if the ping never does: a hub that is gone
    /// is exactly the one whose pong never comes back, so waiting for the ping
    /// would be waiting forever again. The losing side finishes on its own —
    /// the caller cancels the socket, which fails the outstanding ping.
    static func answered(
        within deadline: Duration, ping: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.finish(await ping()) }
            Task {
                try? await Task.sleep(for: deadline)
                once.finish(false)
            }
        }
    }

    /// Pings every `interval` until one goes unanswered, then calls `onSilent`
    /// once and returns. Cancellation — the stream ending for some other reason
    /// — ends it without a call.
    static func watch(
        every interval: Duration,
        deadline: Duration,
        ping: @escaping @Sendable () async -> Bool,
        onSilent: @Sendable () async -> Void
    ) async {
        while true {
            do { try await Task.sleep(for: interval) } catch { return }
            let ok = await answered(within: deadline, ping: ping)
            if Task.isCancelled { return }
            if !ok {
                await onSilent()
                return
            }
        }
    }
}
