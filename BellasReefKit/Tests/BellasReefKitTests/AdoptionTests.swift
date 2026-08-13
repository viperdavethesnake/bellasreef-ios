// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

/// Stub bodies for the adoption endpoints. Wire format is snake_case.
private let oneFreeChannel = #"""
[{"source": "pca9685", "channel": "0",
  "detail": {"i2c_address": "0x40"},
  "announced_at": "2026-08-13T00:00:00Z", "bound_to": null}]
"""#

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

@Suite("Adoption wrappers")
struct AdoptionTests {

    @Test("capabilities decode, including a null bound_to")
    func capabilitiesDecode() async throws {
        let client = stub { _ in (200, json(oneFreeChannel)) }
        let rows = try await client.capabilities()
        #expect(rows.count == 1)
        #expect(rows[0].source.rawValue == "pca9685")
        #expect(rows[0].channel == "0")
        #expect(rows[0].boundTo == nil)
    }

    @Test("a successful bind reports the hub's id and whether it created")
    func bindSucceeds() async throws {
        let client = stub { operation in
            #expect(operation == "bindDevice")
            return (200, json(#"""
                {"device_id": "led-blue", "created": false,
                 "driver_type": "pca9685", "channel": "0"}
                """#))
        }
        let outcome = try await client.bind(
            .init(channel: "0", deviceId: "pca9685-0", displayName: "Blue light",
                  driverType: .pca9685, role: .light)
        )
        // created: false is match-before-create: the channel already carried
        // a device, the hub adopted it in place and its id wins over ours.
        #expect(outcome == .bound(deviceId: "led-blue", created: false))
    }

    @Test("each documented refusal is its own outcome")
    func bindRefusals() async throws {
        for (status, expected) in [(404, HubClient.BindOutcome.channelGone),
                                   (409, .alreadyBound),
                                   (422, .roleNotLegal)] {
            let client = stub { _ in (status, json(#"{"detail": "refused"}"#)) }
            let outcome = try await client.bind(
                .init(channel: "0", deviceId: "pca9685-0", displayName: "Blue light",
                      driverType: .pca9685, role: .light)
            )
            #expect(outcome == expected, "status \(status)")
        }
    }

    @Test("unbind distinguishes done from already-done")
    func unbindOutcomes() async throws {
        let gone = stub { _ in (204, nil) }
        #expect(try await gone.unbind(deviceId: "led-blue") == .unbound)
        let already = stub { _ in (404, json(#"{"detail": "no such device"}"#)) }
        #expect(try await already.unbind(deviceId: "led-blue") == .alreadyUnbound)
    }
}
