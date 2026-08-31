// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

// MARK: - Formatting

@Suite("Hub status formatting")
struct HubStatusFormatTests {

    /// Coco's measured values (2026-08-31), the same fixtures the backend's
    /// tests pin — 990 MB board, 46.3 °C, 28 minutes up. Truncated MB, the
    /// same arithmetic `free -m` prints, so the app and the host agree.
    @Test("memory line reads used of total, in MB")
    func memoryLine() {
        #expect(
            HubStatusFormat.memoryLine(totalKB: 1_014_464, availableKB: 445_792)
                == "555 MB of 990 MB")
    }

    @Test("memory fraction is used over total")
    func memoryFraction() {
        let fraction = HubStatusFormat.memoryFraction(totalKB: 1_014_464, availableKB: 445_792)
        #expect(abs(fraction - 0.5606) < 0.001)
    }

    @Test("memory handles a zero total without dividing by it")
    func memoryZeroTotal() {
        #expect(HubStatusFormat.memoryFraction(totalKB: 0, availableKB: 0) == 0)
    }

    @Test("load line carries the three averages")
    func loadLine() {
        #expect(HubStatusFormat.loadLine(load1m: 0.42, load5m: 0.38, load15m: 0.33)
            == "0.42 · 0.38 · 0.33")
    }

    @Test("temperature renders tenths; nil is an em dash, never zero")
    func temperature() {
        #expect(HubStatusFormat.temperatureLine(tempC: 46.3) == "46.3 °C")
        #expect(HubStatusFormat.temperatureLine(tempC: nil) == "—")
    }

    @Test("uptime picks its unit by scale")
    func uptime() {
        #expect(HubStatusFormat.uptimeLine(seconds: 1692.78) == "28 min")
        #expect(HubStatusFormat.uptimeLine(seconds: 3 * 3600 + 12 * 60) == "3 h 12 min")
        #expect(HubStatusFormat.uptimeLine(seconds: 5 * 86400 + 4 * 3600) == "5 d 4 h")
        #expect(HubStatusFormat.uptimeLine(seconds: 42) == "less than a minute")
    }
}

// MARK: - Client wrapper

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

@Suite("Hub status wrapper")
struct HubStatusClientTests {

    @Test("a 200 decodes the snapshot, nullable temp included")
    func decodes() async throws {
        let client = stub { operation in
            #expect(operation == "getHubStatus")
            return (200, json(#"""
                {"load_1m": 0.42, "load_5m": 0.38, "load_15m": 0.33,
                 "cpu_count": 4, "mem_total_kb": 1014464,
                 "mem_available_kb": 445792, "temp_c": 46.3,
                 "uptime_s": 1692.78, "updated_at": "2026-08-31T21:00:00Z"}
                """#))
        }
        let status = try await client.hubStatus()
        #expect(status?.load1m == 0.42)
        #expect(status?.cpuCount == 4)
        #expect(status?.tempC == 46.3)
    }

    @Test("a 404 is not-yet, not an error — a fresh boot or a pre-4.3 hub")
    func notYet() async throws {
        let client = stub { _ in (404, nil) }
        let status = try await client.hubStatus()
        #expect(status == nil)
    }
}
