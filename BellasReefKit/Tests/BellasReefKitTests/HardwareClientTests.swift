// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

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

@Suite("Hardware wrapper")
struct HardwareClientTests {

    /// The three chips the bench hub actually announces today, verbatim
    /// shapes from `GET /api/v1/hardware` (backend #62): facts values mix
    /// strings, ints, floats and bools, and every one must survive decoding.
    @Test("a 200 decodes every chip row, facts included")
    func hardwareDecodes() async throws {
        let client = stub { operation in
            #expect(operation == "listHardware")
            return (200, json(#"""
                [{"source": "pca9685", "instance": "0x40@1", "initialised": true,
                  "initialised_at": "2026-08-22T01:30:00Z",
                  "facts": {"address": "0x40", "bus": 1, "pre_scale": 12,
                            "frequency_hz": 502.7, "oscillator_hz": 26770000,
                            "invrt": false, "open_drain": false, "channels": 16,
                            "pre_scale_read_back": 12},
                  "announced_at": "2026-08-22T01:30:00Z"},
                 {"source": "pi-pwm", "instance": "1f00098000.pwm", "initialised": true,
                  "initialised_at": "2026-08-22T01:30:00Z",
                  "facts": {"chip": "pwmchip0", "device": "1f00098000.pwm",
                            "period_ns": 2000000, "frequency_hz": 500.0,
                            "polarity": "normal", "channels": 4},
                  "announced_at": "2026-08-22T01:30:00Z"},
                 {"source": "w1-bus", "instance": "w1_bus_master1", "initialised": true,
                  "initialised_at": "2026-08-22T01:30:00Z",
                  "facts": {"bus_master": "w1_bus_master1", "probes": 1},
                  "announced_at": "2026-08-22T01:30:00Z"}]
                """#))
        }
        let chips = try await client.hardware()
        #expect(chips.count == 3)
        #expect(chips[0].source == "pca9685")
        #expect(chips[0].instance == "0x40@1")
        #expect(chips[0].initialised == true)
        #expect(chips[1].facts.additionalProperties["polarity"]?.value1 == "normal")
        #expect(chips[2].facts.additionalProperties["probes"]?.value2 == 1)
    }
}
