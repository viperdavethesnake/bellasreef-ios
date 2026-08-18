// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation
import Testing

@testable import BellasReefKit

/// UX review A3 (the part that held): staleness was one constant, 60 s, for
/// every probe — while each probe declares its own poll cadence. A probe
/// polled every five minutes is not stale after one; a probe polled every
/// five seconds is stale long before sixty. The threshold follows the cadence.
@Suite("Staleness follows the probe's cadence")
@MainActor
struct StalenessTests {
    private let hub = Hub(name: "hub", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false)

    private func monitor(cadence: TimeInterval?) throws -> (TankMonitor, Date) {
        let client = HubClient(hub: hub, tokens: MemoryCredentials(token: "t"),
                               transport: StubTransport { _, _, _ in (500, nil) })
        let monitor = TankMonitor(client: client, stream: StreamClient(baseURL: hub.baseURL))
        monitor.cadenceOf = { _ in cadence }
        let frame = try StreamClient(baseURL: hub.baseURL).decode(Fixtures.sensor)
        monitor.apply(frame)
        // The fixture's emitted_at is the reading's observedAt.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observed = f.date(from: "2026-08-10T06:25:22.367842Z")!
        return (monitor, observed)
    }

    @Test("with no cadence known, the 60 s floor applies")
    func floorWithoutCadence() throws {
        let (m, at) = try monitor(cadence: nil)
        #expect(!m.isStale("ds18b20-28-000000bfe244", now: at.addingTimeInterval(59)))
        #expect(m.isStale("ds18b20-28-000000bfe244", now: at.addingTimeInterval(61)))
    }

    @Test("a slow probe is not stale after a minute")
    func slowProbe() throws {
        let (m, at) = try monitor(cadence: 300)
        #expect(!m.isStale("ds18b20-28-000000bfe244", now: at.addingTimeInterval(120)))
        #expect(!m.isStale("ds18b20-28-000000bfe244", now: at.addingTimeInterval(899)))
        #expect(m.isStale("ds18b20-28-000000bfe244", now: at.addingTimeInterval(901)))
    }

    @Test("a fast probe still gets the 60 s floor — three misses at 5 s is not yet news")
    func fastProbeFloor() throws {
        let (m, at) = try monitor(cadence: 5)
        #expect(!m.isStale("ds18b20-28-000000bfe244", now: at.addingTimeInterval(30)))
        #expect(m.isStale("ds18b20-28-000000bfe244", now: at.addingTimeInterval(61)))
    }
}

