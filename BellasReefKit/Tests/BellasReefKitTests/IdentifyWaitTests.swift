// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

/// The rebuild wait behind Identify (C4): a frame for the new device id whose
/// emitted_at clears the floor taken before the bind. BR_STATE is retained
/// last-value and replayed on connect, so a re-adopted channel can show a
/// frame from its previous life; that frame must not count.
@MainActor
@Suite("Identify: waiting for a fresh state frame")
struct IdentifyWaitTests {
    private let hub = Hub(
        name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
    )

    private func stateJSON(id: String, duty: Double, emittedAt: String) -> String {
        """
        {"frame_version":1,"received_at":"2026-09-04T18:00:00.000000Z","kind":"state",\
        "subject":"bellasreef.state.\(id)","payload":{"schema_version":2,\
        "message_id":"\(UUID().uuidString.lowercased())","emitted_at":"\(emittedAt)",\
        "source":"hardware-io","actuator_id":"\(id)","level":{"kind":"pwm","duty":\(duty)},\
        "reason":"startup","since":"\(emittedAt)","latched":false},"override":null}
        """
    }

    private func monitor() -> (TankMonitor, StreamClient) {
        let client = HubClient(
            hub: hub, tokens: MemoryCredentials(token: "t"),
            transport: StubTransport { _, _, _ in (500, nil) }
        )
        let stream = StreamClient(baseURL: hub.baseURL)
        return (TankMonitor(client: client, stream: stream), stream)
    }

    private func duty(_ frame: Components.Schemas.StateFrame?) -> Double? {
        guard case let .pwm(level)? = frame?.payload.level else { return nil }
        return level.duty
    }

    private let t0 = "2026-09-04T17:00:00.000000Z"
    private var t0Date: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: "2026-09-04T17:00:00.000000Z")!
    }
    private let t1 = "2026-09-04T17:00:20.000000Z"

    @Test("a held frame newer than the floor resolves at once")
    func heldNewerResolvesImmediately() async throws {
        let (m, s) = monitor()
        m.apply(try s.decode(stateJSON(id: "pca9685-3", duty: 0.0, emittedAt: t1)))
        let frame = await m.nextFrame(for: "pca9685-3", newerThan: t0Date, timeout: .seconds(1))
        #expect(duty(frame) == 0.0)
        #expect(!m.isWaitingForFrame(for: "pca9685-3"))
    }

    @Test("a retained frame at or before the floor does not satisfy the wait")
    func retainedOlderDoesNotSatisfy() async throws {
        let (m, s) = monitor()
        m.apply(try s.decode(stateJSON(id: "pca9685-3", duty: 0.7, emittedAt: t0)))
        let frame = await m.nextFrame(for: "pca9685-3", newerThan: t0Date, timeout: .milliseconds(30))
        #expect(frame == nil)
    }

    @Test("a live frame that clears the floor resolves a pending wait")
    func liveFrameResolves() async throws {
        let (m, s) = monitor()
        m.apply(try s.decode(stateJSON(id: "pca9685-3", duty: 0.7, emittedAt: t0)))
        let pending = Task { await m.nextFrame(for: "pca9685-3", newerThan: t0Date, timeout: .seconds(5)) }
        while !m.isWaitingForFrame(for: "pca9685-3") { await Task.yield() }
        m.apply(try s.decode(stateJSON(id: "pca9685-3", duty: 0.0, emittedAt: t1)))
        let frame = await pending.value
        #expect(duty(frame) == 0.0)
        #expect(!m.isWaitingForFrame(for: "pca9685-3"))
    }

    @Test("a live frame for another id does not resolve the wait")
    func otherIdIsIgnored() async throws {
        let (m, s) = monitor()
        let pending = Task { await m.nextFrame(for: "pca9685-3", newerThan: nil, timeout: .milliseconds(60)) }
        while !m.isWaitingForFrame(for: "pca9685-3") { await Task.yield() }
        m.apply(try s.decode(stateJSON(id: "pca9685-4", duty: 0.0, emittedAt: t1)))
        let frame = await pending.value
        #expect(frame == nil)
    }

    @Test("no frame by the timeout resolves nil and leaves no waiter behind")
    func timeoutResolvesNil() async {
        let (m, _) = monitor()
        let frame = await m.nextFrame(for: "never", newerThan: nil, timeout: .milliseconds(20))
        #expect(frame == nil)
        #expect(!m.isWaitingForFrame(for: "never"))
    }

    @Test("with no floor, any frame counts")
    func nilFloorAcceptsAnyFrame() async throws {
        let (m, s) = monitor()
        m.apply(try s.decode(stateJSON(id: "pca9685-3", duty: 0.7, emittedAt: t0)))
        let frame = await m.nextFrame(for: "pca9685-3", newerThan: nil, timeout: .seconds(1))
        #expect(duty(frame) == 0.7)
    }
}
