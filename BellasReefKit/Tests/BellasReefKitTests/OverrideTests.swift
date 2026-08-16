// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

/// `hold`/`release` wrap `createOverride`/`releaseOverride` (Feature 2:
/// lighting manual control). `StubTransport`/`MemoryCredentials` are declared
/// in PairingTests.swift and shared across this test target; `anyHub`/`json`
/// are file-private there, so this file keeps its own copies — the same
/// choice AdoptionTests.swift already made.
private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

private func stub(_ handler: @escaping @Sendable (String) async throws -> (Int, Data?)) -> HubClient {
    HubClient(
        hub: anyHub, tokens: MemoryCredentials(token: "refresh"),
        transport: StubTransport { operation, _, _ in
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            return try await handler(operation)
        }
    )
}

@Suite("Override wrappers")
struct OverrideTests {

    @Test("a 200 grant carries the override the hub created, id included")
    func holdGrants() async throws {
        let client = stub { operation in
            #expect(operation == "createOverride")
            return (200, json(#"""
                {"id": "8f14e45f-ceea-467e-9575-6e3c8e9caeb2", "target": "light-1",
                 "duty": 0.6, "expires_at": "2026-08-15T00:20:00Z", "expires_in_s": 1200}
                """#))
        }
        let outcome = try await client.hold(
            target: "light-1", duty: 0.6, durationS: 1200, reason: "manual"
        )
        guard case let .granted(override) = outcome else {
            Issue.record("expected .granted, got \(outcome)")
            return
        }
        #expect(override.id == "8f14e45f-ceea-467e-9575-6e3c8e9caeb2")
        #expect(override.duty == 0.6)
        #expect(override.expiresInS == 1200)
    }

    @Test("a 409 means the target does not accept commands — observe-only, not a thrown error")
    func holdRefusedObserveOnly() async throws {
        let client = stub { _ in (409, nil) }
        let outcome = try await client.hold(
            target: "light-1", duty: 0.6, durationS: 1200, reason: "manual"
        )
        #expect(outcome == .notCommandable)
    }

    /// The clock-untrusted 503 must be its own case, not a thrown generic
    /// error — the UI renders pinned copy for exactly this state (constraints
    /// block, plan 2026-08-15).
    @Test("a 503 is the clock-untrusted case, distinct from a generic failure")
    func holdClockUntrusted() async throws {
        let client = stub { _ in (503, nil) }
        let outcome = try await client.hold(
            target: "light-1", duty: 0.6, durationS: 1200, reason: "manual"
        )
        #expect(outcome == .clockUntrusted)
    }

    @Test("hold's request carries duty, duration and reason in the hub's snake_case")
    func holdRequestBody() async throws {
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "refresh"),
            transport: StubTransport { operation, _, body in
                if operation == "mintToken" {
                    return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
                }
                #expect(operation == "createOverride")
                let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                #expect(parsed?["target"] as? String == "light-1")
                #expect(parsed?["duty"] as? Double == 0.6)
                #expect(parsed?["duration_s"] as? Double == 1200)
                #expect(parsed?["reason"] as? String == "manual")
                return (200, json(#"""
                    {"id": "8f14e45f-ceea-467e-9575-6e3c8e9caeb2", "target": "light-1",
                     "duty": 0.6, "expires_at": "2026-08-15T00:20:00Z", "expires_in_s": 1200}
                    """#))
            }
        )
        _ = try await client.hold(target: "light-1", duty: 0.6, durationS: 1200, reason: "manual")
    }

    @Test("a 200 release is done, a 404 means already-done — the hold is gone either way")
    func releaseOutcomes() async throws {
        let released = stub { operation in
            #expect(operation == "releaseOverride")
            return (200, json("{}"))
        }
        #expect(try await released.release(overrideId: "8f14e45f-ceea-467e-9575-6e3c8e9caeb2") == .released)

        let already = stub { _ in (404, nil) }
        #expect(
            try await already.release(overrideId: "8f14e45f-ceea-467e-9575-6e3c8e9caeb2")
                == .alreadyReleased
        )
    }

    @Test("release sends the override id on the path, not the body")
    func releaseUsesThePath() async throws {
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "refresh"),
            transport: StubTransport { operation, request, _ in
                if operation == "mintToken" {
                    return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
                }
                #expect(operation == "releaseOverride")
                #expect(request.path?.hasSuffix("8f14e45f-ceea-467e-9575-6e3c8e9caeb2") == true)
                return (200, json("{}"))
            }
        )
        _ = try await client.release(overrideId: "8f14e45f-ceea-467e-9575-6e3c8e9caeb2")
    }
}
