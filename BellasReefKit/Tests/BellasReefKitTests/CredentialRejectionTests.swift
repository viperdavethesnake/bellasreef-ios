// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

/// A flag the rejection handler can set from any context, matching the
/// `MemoryCredentials` idiom above rather than inventing a second one.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

/// Found live on 2026-08-13: a device revoked from another phone kept showing
/// its screens with inline errors forever, because the only wiring from "the
/// hub proved this credential dead" to "land on the pairing screen" ran
/// through the telemetry stream — and a revoked device's stream, authenticated
/// at handshake, never reconnects.
@Suite("Revocation reaches the app layer")
struct CredentialRejectionTests {

    @Test("mintToken rejecting the refresh token fires the rejection handler")
    func refreshRejectionNotifies() async throws {
        let transport = StubTransport { operation, _, _ in
            #expect(operation == "mintToken")
            return (401, nil)
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "dead-refresh"), transport: transport
        )
        let flag = Flag()
        await client.notifyCredentialRejected { flag.raise() }

        await #expect(throws: HubClient.ClientError.self) {
            _ = try await client.accessTokenNow()
        }
        #expect(flag.isRaised, "a proven-dead refresh token must reach the app layer")
    }

    @Test("a plain 401 on a data call does not fire the handler")
    func staleAccessTokenStaysQuiet() async throws {
        // The hub 401s the data call (stale access token) but would happily
        // mint a fresh one — this device is NOT revoked, and unpairing it over
        // a stale token would be the opposite bug.
        let transport = StubTransport { operation, _, _ in
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            return (401, nil)
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "live-refresh"), transport: transport
        )
        let flag = Flag()
        await client.notifyCredentialRejected { flag.raise() }

        await #expect(throws: HubClient.ClientError.self) {
            _ = try await client.sensors()
        }
        #expect(!flag.isRaised, "a stale access token is not a revocation")
    }
}
