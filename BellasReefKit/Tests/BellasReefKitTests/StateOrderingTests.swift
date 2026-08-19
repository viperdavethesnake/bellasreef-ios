// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation
import Testing

@testable import BellasReefKit

/// H3 (2026-08-18): the hub replays each actuator's last known state when a
/// socket connects, then joins the live fan-out. A change that lands in the
/// gap between the two reaches the client *after* its own replayed
/// predecessor. Frames carry `emitted_at`; the monitor keeps the newer and
/// never lets an older frame overwrite it.
@Suite("State frames never regress")
@MainActor
struct StateOrderingTests {
    private let hub = Hub(name: "hub", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false)

    private func stateJSON(duty: Double, emittedAt: String) -> String {
        """
        {"frame_version":1,"received_at":"2026-08-18T21:00:00.000000Z","kind":"state",\
        "subject":"bellasreef.state.pca9685-0","payload":{"schema_version":2,\
        "message_id":"\(UUID().uuidString.lowercased())","emitted_at":"\(emittedAt)",\
        "source":"hardware-io","actuator_id":"pca9685-0","level":{"kind":"pwm","duty":\(duty)},\
        "reason":"commanded","since":"\(emittedAt)","latched":false},"override":null}
        """
    }

    private func monitor() -> (TankMonitor, StreamClient) {
        let client = HubClient(hub: hub, tokens: MemoryCredentials(token: "t"),
                               transport: StubTransport { _, _, _ in (500, nil) })
        let stream = StreamClient(baseURL: hub.baseURL)
        return (TankMonitor(client: client, stream: stream), stream)
    }

    @Test("a newer frame replaces an older one")
    func newerWins() throws {
        let (m, s) = monitor()
        m.apply(try s.decode(stateJSON(duty: 0.2, emittedAt: "2026-08-18T20:00:00.000000Z")))
        m.apply(try s.decode(stateJSON(duty: 0.5, emittedAt: "2026-08-18T20:00:05.000000Z")))
        #expect(duty(m) == 0.5)
    }

    @Test("an older frame arriving late — a replay behind a live change — is ignored")
    func olderIgnored() throws {
        let (m, s) = monitor()
        m.apply(try s.decode(stateJSON(duty: 0.5, emittedAt: "2026-08-18T20:00:05.000000Z")))
        m.apply(try s.decode(stateJSON(duty: 0.2, emittedAt: "2026-08-18T20:00:00.000000Z")))
        #expect(duty(m) == 0.5)
    }

    private func duty(_ m: TankMonitor) -> Double? {
        guard let frame = m.channels["pca9685-0"] else { return nil }
        if case let .pwm(level) = frame.payload.level { return level.duty }
        return nil
    }
}
