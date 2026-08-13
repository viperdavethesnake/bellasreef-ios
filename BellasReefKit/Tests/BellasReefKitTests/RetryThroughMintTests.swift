// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

/// Found live 2026-08-13: a device revoked 16 s after minting took two
/// interactions to land on the pairing screen — the first burned the cached
/// token as an inline error, only the second forced the mint that proved the
/// revocation. The middleware now spends that first interaction properly.
@Suite("Retry through a fresh mint")
struct RetryThroughMintTests {

    /// The hub 401s a data call (stale access token) but mints happily. The
    /// operator must never see it.
    @Test("a stale access token is retried invisibly")
    func staleTokenRetriesInvisibly() async throws {
        let log = CallLog()
        let transport = StubTransport { operation, _, _ in
            await log.record(operation)
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            // First data attempt 401s, the retry succeeds.
            if await log.count(of: operation) == 1 { return (401, nil) }
            return (200, json("[]"))
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "refresh"), transport: transport
        )
        let flag = Flag()
        await client.notifyCredentialRejected { flag.raise() }

        let sensors = try await client.sensors()

        #expect(sensors.isEmpty)
        #expect(await log.count(of: "listSensors") == 2, "one retry, exactly")
        #expect(await log.count(of: "mintToken") == 2, "the retry re-minted")
        #expect(!flag.isRaised, "a stale token is not a revocation")
    }

    /// A revoked device: the retry's mint is rejected, the handler fires,
    /// the call throws. One interaction, one landing.
    @Test("a revoked device is told on the first interaction")
    func revokedDeviceLandsFirstTry() async throws {
        let log = CallLog()
        let transport = StubTransport { operation, _, _ in
            await log.record(operation)
            if operation == "mintToken" {
                // First mint succeeds (the device does not know yet); the
                // forced re-mint meets the revocation.
                if await log.count(of: "mintToken") == 1 {
                    return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
                }
                return (401, nil)
            }
            return (401, nil)
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "refresh"), transport: transport
        )
        let flag = Flag()
        await client.notifyCredentialRejected { flag.raise() }

        await #expect(throws: HubClient.ClientError.self) {
            _ = try await client.sensors()
        }
        #expect(flag.isRaised, "the rejected re-mint must reach the app layer")
        #expect(await log.count(of: "listSensors") == 1, "no resend after a rejected mint")
    }

    /// Both attempts 401 while mints succeed (a hub-side authorization quirk,
    /// not a dead credential): give up after one retry, stay quiet.
    @Test("a persistent 401 is thrown after exactly one retry")
    func persistent401StopsAfterOneRetry() async throws {
        let log = CallLog()
        let transport = StubTransport { operation, _, _ in
            await log.record(operation)
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            return (401, nil)
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "refresh"), transport: transport
        )
        let flag = Flag()
        await client.notifyCredentialRejected { flag.raise() }

        await #expect(throws: HubClient.ClientError.self) {
            _ = try await client.sensors()
        }
        #expect(await log.count(of: "listSensors") == 2, "exactly one retry, never a loop")
        #expect(!flag.isRaised)
    }
}
