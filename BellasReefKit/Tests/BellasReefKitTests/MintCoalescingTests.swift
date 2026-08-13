// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

/// Observed live 2026-08-13: two `token.minted` audit rows 38 µs apart from
/// one device. The actor suspends across `await mintToken`, so a second
/// caller finds no cached token and starts a second mint.
@Suite("Mint coalescing")
struct MintCoalescingTests {

    @Test("two concurrent callers share one mint")
    func concurrentCallersCoalesce() async throws {
        let log = CallLog()
        let transport = StubTransport { operation, _, _ in
            await log.record(operation)
            // Long enough that the second caller arrives while the first
            // mint is on the wire.
            try await Task.sleep(for: .milliseconds(80))
            return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "refresh"), transport: transport
        )

        async let first = client.accessTokenNow()
        async let second = client.accessTokenNow()
        let (a, b) = try await (first, second)

        #expect(a == "jwt" && b == "jwt")
        #expect(await log.count(of: "mintToken") == 1, "concurrent callers must share one mint")
    }

    @Test("freshAccessTokenNow ignores the cache but joins an in-flight mint")
    func forcedFreshMints() async throws {
        let log = CallLog()
        let transport = StubTransport { operation, _, _ in
            await log.record(operation)
            return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "refresh"), transport: transport
        )

        _ = try await client.accessTokenNow()          // mint 1, cached
        _ = try await client.accessTokenNow()          // cache hit, no mint
        _ = try await client.freshAccessTokenNow()     // must mint again
        #expect(await log.count(of: "mintToken") == 2, "forced fresh must not trust the cache")
    }
}
