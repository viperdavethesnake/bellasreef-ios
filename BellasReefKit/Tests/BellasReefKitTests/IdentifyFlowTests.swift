// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

/// Request bodies by operation id, so a test can assert what went on the wire.
/// A lock-protected class rather than an actor: `[String: Any]` is not
/// Sendable, so it must not cross an actor boundary (same idiom as
/// `CapturedBody` in AdoptionTests).
private final class Bodies: @unchecked Sendable {
    private let lock = NSLock()
    private var byOperation: [String: [Data]] = [:]
    func record(_ operation: String, _ body: Data) {
        lock.withLock { byOperation[operation, default: []].append(body) }
    }
    func last(_ operation: String) -> [String: Any]? {
        guard let data = lock.withLock({ byOperation[operation]?.last }), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// A frame source the test scripts: what is held before the bind, and what
/// the wait resolves to. Records the floor the flow asked for.
@MainActor
private final class CannedFrames: StateFrameSource {
    var held: Components.Schemas.StateFrame?
    var next: Components.Schemas.StateFrame?
    private(set) var askedFloor: Date??
    func heldFrame(for deviceId: String) -> Components.Schemas.StateFrame? { held }
    func nextFrame(
        for deviceId: String, newerThan floor: Date?, timeout: Duration
    ) async -> Components.Schemas.StateFrame? {
        askedFloor = .some(floor)
        return next
    }
}

private func stateFrame(emittedAt: String) throws -> Components.Schemas.StateFrame {
    let text = """
        {"frame_version":1,"received_at":"2026-09-04T18:00:00.000000Z","kind":"state",\
        "subject":"bellasreef.state.pca9685-3","payload":{"schema_version":2,\
        "message_id":"\(UUID().uuidString.lowercased())","emitted_at":"\(emittedAt)",\
        "source":"hardware-io","actuator_id":"pca9685-3","level":{"kind":"pwm","duty":0.0},\
        "reason":"startup","since":"\(emittedAt)","latched":false},"override":null}
        """
    guard case let .state(frame) = try StreamClient(baseURL: anyHub.baseURL).decode(text) else {
        throw HubClient.ClientError.unexpected("not a state frame")
    }
    return frame
}

private let boundCreated = #"{"device_id":"pca9685-3","created":true,"driver_type":"pca9685","channel":"3"}"#
private let boundMatched = #"{"device_id":"pca9685-3","created":false,"driver_type":"pca9685","channel":"3"}"#
private let granted = #"{"id":"6f1c2a4e-0000-4000-8000-000000000001","target":"pca9685-3","duty":0.5,"expires_at":"2026-09-04T18:00:05Z","expires_in_s":5.0,"transition":"snap"}"#
private let renamed = #"{"device_id":"pca9685-3","display_name":"Left fixture"}"#

/// A hub that answers every call the flow can make; `overrideStatus` lets one
/// test refuse the pulse.
private func hub(
    log: CallLog, bodies: Bodies, bind: String, overrideStatus: Int = 200
) -> HubClient {
    HubClient(
        hub: anyHub, tokens: MemoryCredentials(token: "refresh"),
        transport: StubTransport { operation, _, body in
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            await log.record(operation)
            bodies.record(operation, body)
            switch operation {
            case "bindDevice": return (200, json(bind))
            case "createOverride": return (overrideStatus, overrideStatus == 200 ? json(granted) : nil)
            case "renameDevice": return (200, json(renamed))
            case "unbindDevice", "forgetDevice": return (204, nil)
            case "releaseOverride": return (204, nil)
            default: return (500, nil)
            }
        }
    )
}

private func request() -> Components.Schemas.BindDeviceRequest {
    .init(channel: "3", deviceId: "pca9685-3", driverType: .pca9685, role: .light)
}

@MainActor
@Suite("Identify flow (C4)")
struct IdentifyFlowTests {
    private func makeFlow(
        _ client: HubClient, frames: CannedFrames, timeout: Duration = .seconds(1)
    ) -> IdentifyFlow {
        IdentifyFlow(
            client: client, frames: frames, request: request(), channel: "3",
            rebuildTimeout: timeout, pulseSettle: .milliseconds(1)
        )
    }

    @Test("happy path: adopt nameless, wait, pulse at 50 % for 5 s, name")
    func happyPath() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        let flow = makeFlow(hub(log: log, bodies: bodies, bind: boundCreated), frames: frames)

        #expect(flow.phase == .choose)
        #expect(flow.channelLabel == "PWM ch 3")
        let outcome = try await flow.start()
        #expect(outcome == .bound(deviceId: "pca9685-3", created: true))
        await flow.settle()
        #expect(flow.phase == .answer)
        #expect(flow.adopted)
        #expect(flow.created == true)
        #expect(frames.askedFloor == .some(nil), "nothing held, so any frame counts")

        flow.chooseToName()
        #expect(flow.phase == .naming)
        await flow.name("Left fixture")
        #expect(flow.phase == .named)

        #expect(await log.operations == ["bindDevice", "createOverride", "renameDevice"])
        let bind = bodies.last("bindDevice")
        #expect(bind?["display_name"] == nil, "identify adopts nameless")
        #expect(bind?["device_id"] as? String == "pca9685-3")
        #expect(bind?["role"] as? String == "light")
        let pulse = bodies.last("createOverride")
        #expect(pulse?["target"] as? String == "pca9685-3")
        #expect(pulse?["duty"] as? Double == 0.5)
        #expect(pulse?["duration_s"] as? Double == 5.0)
        #expect(pulse?["transition"] as? String == "snap")
        #expect(pulse?["reason"] as? String == "identify")
        let rename = bodies.last("renameDevice")
        #expect(rename?["display_name"] as? String == "Left fixture")
    }

    @Test("the floor is the frame held before the bind")
    func floorIsTheHeldFrame() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        let old = try stateFrame(emittedAt: "2026-09-04T17:00:00.000000Z")
        frames.held = old
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        let flow = makeFlow(hub(log: log, bodies: bodies, bind: boundMatched), frames: frames)
        _ = try await flow.start()
        await flow.settle()
        #expect(frames.askedFloor == .some(old.payload.emittedAt))
        #expect(flow.created == false)
    }

    @Test("pulse again repeats the override without another bind")
    func pulseAgain() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        let flow = makeFlow(hub(log: log, bodies: bodies, bind: boundCreated), frames: frames)
        _ = try await flow.start()
        await flow.settle()
        flow.pulseAgain()
        await flow.settle()
        #expect(flow.phase == .answer)
        #expect(await log.count(of: "bindDevice") == 1)
        #expect(await log.count(of: "createOverride") == 2)
    }

    @Test("not this one on a matched row unbinds and does not forget")
    func notThisOneMatched() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        let flow = makeFlow(hub(log: log, bodies: bodies, bind: boundMatched), frames: frames)
        _ = try await flow.start()
        await flow.settle()
        flow.leave()
        await flow.settle()
        #expect(flow.phase == .left)
        #expect(await log.count(of: "unbindDevice") == 1)
        #expect(await log.count(of: "forgetDevice") == 0, "the row predates this flow; forgetting it deletes a device the operator built")
    }

    @Test("not this one on a created row unbinds then forgets")
    func notThisOneCreated() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        let flow = makeFlow(hub(log: log, bodies: bodies, bind: boundCreated), frames: frames)
        _ = try await flow.start()
        await flow.settle()
        flow.leave()
        await flow.settle()
        #expect(flow.phase == .left)
        #expect(await log.operations.suffix(2) == ["unbindDevice", "forgetDevice"])
    }

    @Test("an untrusted clock fails the pulse and leaves the adoption standing")
    func clockUntrusted() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        let flow = makeFlow(hub(log: log, bodies: bodies, bind: boundCreated, overrideStatus: 503), frames: frames)
        _ = try await flow.start()
        await flow.settle()
        guard case .failed(_, .pulse) = flow.phase else {
            Issue.record("expected .failed(retry: .pulse), got \(flow.phase)")
            return
        }
        #expect(flow.adopted)
        #expect(await log.count(of: "unbindDevice") == 0)
    }

    @Test("no frame within the timeout fails the wait; retry waits again")
    func rebuildTimeout() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = nil
        let flow = makeFlow(hub(log: log, bodies: bodies, bind: boundCreated), frames: frames, timeout: .milliseconds(1))
        _ = try await flow.start()
        await flow.settle()
        guard case .failed(_, .waitForHub) = flow.phase else {
            Issue.record("expected .failed(retry: .waitForHub), got \(flow.phase)")
            return
        }
        #expect(await log.count(of: "createOverride") == 0, "a pulse into the restart window is silently wrong")
        #expect(flow.adopted)

        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        flow.retry()
        await flow.settle()
        #expect(flow.phase == .answer)
        #expect(await log.count(of: "createOverride") == 1)
    }

    @Test("a refused bind returns to choose with nothing adopted")
    func bindRefused() async throws {
        let log = CallLog(), bodies = Bodies()
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "refresh"),
            transport: StubTransport { operation, _, _ in
                if operation == "mintToken" {
                    return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
                }
                await log.record(operation)
                return (409, nil)
            }
        )
        let flow = makeFlow(client, frames: CannedFrames())
        let outcome = try await flow.start()
        await flow.settle()
        #expect(outcome == .alreadyBound)
        #expect(flow.phase == .choose)
        #expect(!flow.adopted)
        #expect(await log.operations == ["bindDevice"])
    }
}
