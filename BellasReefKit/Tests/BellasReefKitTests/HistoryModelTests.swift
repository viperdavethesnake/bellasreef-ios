// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import BellasReefKit

/// Finding, 2026-08-15: `load()` caught its own task's cancellation — a tab
/// switch cancelling the `.task`, or `range.didSet` racing a second load —
/// and rendered it as `state = .failed("\(error)")`: a permanent screen
/// carrying a raw transport dump, for a request the app itself cancelled.
/// The server side was verified healthy throughout. These tests pin the fix
/// at the model layer: cancellation leaves `state` untouched, and a real
/// failure reads as one sentence via `HumanError`.
private let historyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

/// A `HistoryModel` wired to a real `HubClient` whose transport is stubbed:
/// the mint succeeds (so the request reaches the operation under test at
/// all) and the `history` operation throws whatever this test is probing.
/// Same seam `PairingTests`/`RetryThroughMintTests` use — `HistoryModel`
/// takes the concrete `HubClient`, not a protocol, so the transport is the
/// fake, not the client.
@MainActor
private func makeModel(throwing error: any Error) -> HistoryModel {
    let transport = StubTransport { operation, _, _ in
        if operation == "mintToken" {
            return (200, Data(#"{"access_token":"jwt","expires_in":900}"#.utf8))
        }
        throw error
    }
    let client = HubClient(
        hub: historyHub, tokens: MemoryCredentials(token: "rt"), transport: transport
    )
    return HistoryModel(client: client, catalog: DeviceCatalog(client: client))
}

@MainActor
@Suite("HistoryModel load")
struct HistoryModelTests {

    @Test("a cancelled load (URLError.cancelled) is not rendered as a failure")
    func cancelledLoadLeavesStateAlone() async {
        let model = makeModel(throwing: URLError(.cancelled))
        await model.load()

        if case let .failed(why) = model.state {
            Issue.record("cancellation rendered as a failure: \(why)")
        }
    }

    @Test("Swift's own CancellationError is not rendered as a failure either")
    func swiftCancellationLeavesStateAlone() async {
        let model = makeModel(throwing: CancellationError())
        await model.load()

        if case let .failed(why) = model.state {
            Issue.record("cancellation rendered as a failure: \(why)")
        }
    }

    @Test("a real failure reads as one human sentence, not the raw error")
    func realFailureIsHumanReadable() async {
        let model = makeModel(throwing: URLError(.timedOut))
        await model.load()

        guard case let .failed(why) = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
        #expect(!why.contains("operationID"))
        #expect(!why.contains("NSURLErrorDomain"))
        #expect(why == "The hub did not answer. Check that this device is on the tank's network.")
    }

    @Test("reload() is single-flight: a second call cancels the first's load task")
    func reloadCancelsInFlight() async {
        // The transport never answers the first call, so if the first load
        // were still driving `state` it would still be `.loading` forever.
        // The second `reload()` must cancel it rather than let both race.
        let started = Started()
        let transport = StubTransport { operation, _, _ in
            if operation == "mintToken" {
                return (200, Data(#"{"access_token":"jwt","expires_in":900}"#.utf8))
            }
            await started.mark()
            try await Task.sleep(nanoseconds: .max)
            return (200, Data())
        }
        let client = HubClient(
            hub: historyHub, tokens: MemoryCredentials(token: "rt"), transport: transport
        )
        let model = HistoryModel(client: client, catalog: DeviceCatalog(client: client))

        model.reload()
        // Give the first load a beat to actually start its (never-returning)
        // request before superseding it.
        await started.wait()
        model.reload()

        // The superseded task's `Task.sleep` throws `CancellationError` when
        // cancelled, which `load()` must treat as cancellation-transparent —
        // not as a failure landing after the fact.
        try? await Task.sleep(nanoseconds: 50_000_000)
        if case let .failed(why) = model.state {
            Issue.record("the superseded load's cancellation surfaced as a failure: \(why)")
        }
    }

    /// The exact race from the finding: `.refreshable` calls `refresh()` at
    /// the current range and awaits it — same as pull-to-refresh at 1H — and
    /// while that request is still in flight, `range` flips (to `.week`,
    /// same as picking 7D), which calls `reload()`. Before both went through
    /// the same tracked `loadTask`, neither could cancel the other, so
    /// whichever response happened to arrive last won regardless of which
    /// range was actually selected. The fix means the range flip's request —
    /// fired second — is the one that must survive.
    @Test("a range change wins over a slower in-flight refresh at the old range")
    func laterRangeWinsOverSlowerRefresh() async {
        let started = Started()
        let callIndex = CallIndex()
        let transport = StubTransport { operation, _, _ in
            if operation == "mintToken" {
                return (200, Data(#"{"access_token":"jwt","expires_in":900}"#.utf8))
            }
            // First call in is the pull-to-refresh at the old range: it never
            // answers, standing in for "still in flight when the range
            // changes".
            guard await callIndex.next() > 1 else {
                await started.mark()
                try await Task.sleep(nanoseconds: .max)
                return (200, Data())
            }
            // Second call in is the range flip's request: answered at once,
            // with a series distinct enough to prove whose data landed.
            return (200, historyPayload(deviceId: "week-device", metric: "temp"))
        }
        let client = HubClient(
            hub: historyHub, tokens: MemoryCredentials(token: "rt"), transport: transport
        )
        let model = HistoryModel(client: client, catalog: DeviceCatalog(client: client))

        // `.refreshable`'s own call: awaited concurrently, same as the view
        // does, so it must not block this test while it's stuck in flight.
        async let refreshing: Void = model.refresh()
        await started.wait()

        // The range flip `.refreshable` was racing against.
        model.range = .week
        await refreshing

        // `refreshing` only resolves the superseded call's own task — once
        // cancelled, it returns quickly, same as the real `.refreshable`
        // spinner would stop. It says nothing about whether `reload()`'s
        // replacement task (which nobody here awaits, same as the view
        // never awaits `reload()`) has finished writing `state` yet, so give
        // it a moment before asserting what actually landed.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(model.traces.map(\.id) == ["week-device/temp"])
    }
}

/// One series, one bucket, named distinctly enough that a test can tell
/// whose response actually landed in `state`.
private func historyPayload(deviceId: String, metric: String) -> Data {
    Data("""
    {"start":"2026-01-01T00:00:00Z","end":"2026-01-01T01:00:00Z","bucket_s":60,
     "series":[{"device_id":"\(deviceId)","metric":"\(metric)","unit":"degC",
                 "buckets":[{"at":"2026-01-01T00:01:00Z","minimum":1,"average":1,"maximum":1}]}],
     "episodes":[]}
    """.utf8)
}

/// Thread-safe call counter: `StubTransport`'s handler is `@Sendable` and
/// this test needs to tell the first `history` call apart from the second.
private actor CallIndex {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// Signals once the in-flight request under test has actually begun, so the
/// second `reload()` genuinely supersedes a request in progress rather than
/// racing its own start.
private actor Started {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func mark() {
        hasStarted = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
