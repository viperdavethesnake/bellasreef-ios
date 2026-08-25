// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation
import Testing

@testable import BellasReefKit

/// Rehearsal 2026-08-24, F3: "Waiting for a sensor" assumed a temp probe is
/// wanted. A lighting-only hub — or the post-wipe empty registry — sat amber
/// forever. The line keys on *adopted sensors*, not on the probe stream.
///
/// And F4: the Lighting tab reused the sensor-aware pair wholesale, so sensor
/// copy leaked into a tab about lights. The connection-scoped pair keeps what
/// the 2026-08-15 review wanted — socket honesty and the interlock — and
/// nothing else.
@Suite("Status keys on adopted sensors, not the probe stream")
@MainActor
struct SensorlessStatusTests {
    private let hub = Hub(name: "hub", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false)

    /// A monitor driven to `.live` through the stream path, no probes reporting.
    private func liveMonitor() throws -> TankMonitor {
        let client = HubClient(hub: hub, tokens: MemoryCredentials(token: "t"),
                               transport: StubTransport { _, _, _ in (500, nil) })
        let monitor = TankMonitor(client: client, stream: StreamClient(baseURL: hub.baseURL))
        monitor.apply(try StreamClient(baseURL: hub.baseURL).decode(Fixtures.ready))
        return monitor
    }

    @Test("zero adopted sensors on a live hub is teal, not amber")
    func sensorlessHubIsAllClear() throws {
        let m = try liveMonitor()
        m.adoptedSensorCount = { 0 }
        #expect(m.tone == .allClear)
        #expect(m.statusLine == "No sensors adopted")
    }

    @Test("adopted sensors that have not reported still wait, amber")
    func adoptedButSilentStillWaits() throws {
        let m = try liveMonitor()
        m.adoptedSensorCount = { 1 }
        #expect(m.tone == .attention)
        #expect(m.statusLine == "Waiting for a sensor")
    }

    @Test("registry not loaded yet: the probe-stream fallback holds")
    func unknownRegistryFallsBack() throws {
        let m = try liveMonitor()
        // default adoptedSensorCount = { nil }
        #expect(m.tone == .attention)
        #expect(m.statusLine == "Waiting for a sensor")
    }

    @Test("the connection-scoped line is blind to sensors")
    func connectionScopeIgnoresSensors() throws {
        let m = try liveMonitor()
        m.adoptedSensorCount = { 1 }  // tank scope would say "Waiting for a sensor"
        #expect(m.connectionTone == .allClear)
        #expect(m.connectionLine == "Connected")
    }

    @Test("the connection-scoped line still surfaces a latched interlock")
    func connectionScopeKeepsTheInterlock() throws {
        let m = try liveMonitor()
        let latched = """
        {"frame_version":1,"received_at":"2026-08-25T20:00:00.000000Z","kind":"state",\
        "subject":"bellasreef.state.pca9685-0","payload":{"schema_version":2,\
        "message_id":"\(UUID().uuidString.lowercased())","emitted_at":"2026-08-25T20:00:00.000000Z",\
        "source":"hardware-io","actuator_id":"pca9685-0","level":{"kind":"pwm","duty":0.0},\
        "reason":"interlock_latch","since":"2026-08-25T20:00:00.000000Z","latched":true},"override":null}
        """
        m.apply(try StreamClient(baseURL: hub.baseURL).decode(latched))
        #expect(m.connectionTone == .safety)
        #expect(m.connectionLine == "Interlock latched")
    }

    @Test("a dead socket is amber in connection scope")
    func connectionScopeIsHonestAboutTheSocket() {
        let client = HubClient(hub: hub, tokens: MemoryCredentials(token: "t"),
                               transport: StubTransport { _, _, _ in (500, nil) })
        let m = TankMonitor(client: client, stream: StreamClient(baseURL: hub.baseURL))
        // never driven live
        #expect(m.connectionTone == .attention)
        #expect(m.connectionLine == "Not connected")
    }
}
