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
