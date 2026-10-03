// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

/// Phase B of the 2026-10-02 stream-liveness plan (contracts 4.5.0). The ping
/// (Phase A) proves the api answers; the hub's `host` frame — published by
/// hardware-io every 30 s and carried across NATS — proves the pipeline behind
/// it is flowing. A live socket with no `host` frame for 75 s is "Hub not
/// reporting": connected, but nothing behind the api can be trusted.
@Suite("Hub reporting")
@MainActor
struct HubReportingTests {
    private let hub = Hub(name: "hub", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false)
    private let decoder = StreamClient(baseURL: URL(string: "http://hub.invalid:8000")!)

    static let host = """
    {"frame_version":1,"received_at":"2026-10-03T05:10:00.000000Z","kind":"host",\
    "subject":"bellasreef.host.status","payload":{"schema_version":2,\
    "message_id":"0b6f3a52-5d0e-4a5e-9a7c-0f0e7c2d1a11","emitted_at":"2026-10-03T05:10:00.000000Z",\
    "source":"hardware-io","load_1m":0.42,"load_5m":0.38,"load_15m":0.33,"cpu_count":4,\
    "mem_total_kb":1014464,"mem_available_kb":445792,"temp_c":46.3,"uptime_s":1692.78}}
    """

    private func monitor(sendsHost: Bool) -> TankMonitor {
        let client = HubClient(hub: hub, tokens: MemoryCredentials(token: "t"),
                               transport: StubTransport { _, _, _ in (500, nil) })
        let m = TankMonitor(client: client, stream: StreamClient(baseURL: hub.baseURL))
        m.hubSendsHost = sendsHost
        m.adoptedSensorCount = { 0 }
        return m
    }

    @Test("a host frame decodes into its own case")
    func decodesHost() throws {
        guard case let .host(frame) = try decoder.decode(Self.host) else {
            Issue.record("expected .host")
            return
        }
        #expect(frame.payload.tempC == 46.3)
    }

    @Test("a fresh host frame keeps the hub reporting")
    func freshHostIsReporting() throws {
        let m = monitor(sendsHost: true)
        let now = Date()
        m.apply(try decoder.decode(Fixtures.ready), at: now.addingTimeInterval(-80))
        m.apply(try decoder.decode(Self.host), at: now.addingTimeInterval(-20))

        #expect(m.hubNotReporting(now: now) == false)
        #expect(m.host?.load1m == 0.42)
    }

    @Test("75 s without a host frame on a live socket is Hub not reporting")
    func silentPipelineIsNotReporting() throws {
        let m = monitor(sendsHost: true)
        let past = Date().addingTimeInterval(-80)
        m.apply(try decoder.decode(Fixtures.ready), at: past)
        m.apply(try decoder.decode(Self.host), at: past)

        #expect(m.hubNotReporting())
        #expect(m.statusLine == "Hub not reporting")
        #expect(m.connectionLine == "Hub not reporting")
        #expect(m.tone == .attention)
        #expect(m.connectionTone == .attention)
    }

    @Test("no host frame at all since ready counts from ready")
    func neverReportedCountsFromReady() throws {
        let m = monitor(sendsHost: true)
        let now = Date()
        m.apply(try decoder.decode(Fixtures.ready), at: now.addingTimeInterval(-30))
        #expect(m.hubNotReporting(now: now) == false)
        #expect(m.hubNotReporting(now: now.addingTimeInterval(50)))
    }

    @Test("a hub older than 4.5.0 never sends host frames, so is never flagged")
    func olderHubIsNeverFlagged() throws {
        let m = monitor(sendsHost: false)
        m.apply(try decoder.decode(Fixtures.ready), at: Date().addingTimeInterval(-600))
        #expect(m.hubNotReporting() == false)
        #expect(m.statusLine == "No sensors adopted")
    }

    @Test("contracts version gate", arguments: [
        ("4.5.0", true), ("4.10.0", true), ("5.0.0", true), ("4.4.9", false),
        ("3.9.9", false), ("4.5", true), ("garbage", false),
    ])
    func versionGate(version: String, sends: Bool) {
        #expect(TankMonitor.sendsHostFrames(contractsVersion: version) == sends)
    }
}
