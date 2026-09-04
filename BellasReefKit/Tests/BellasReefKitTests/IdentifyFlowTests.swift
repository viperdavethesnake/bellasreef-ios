// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

/// Request bodies and paths by operation id, so a test can assert what went on
/// the wire. A lock-protected class rather than an actor: `[String: Any]` is
/// not Sendable, so it must not cross an actor boundary (same idiom as
/// `CapturedBody` in AdoptionTests). The paths matter because rename, unbind
/// and forget carry their target in the URL, not in a body.
private final class Bodies: @unchecked Sendable {
    private let lock = NSLock()
    private var byOperation: [String: [Data]] = [:]
    private var pathsByOperation: [String: [String]] = [:]
    func record(_ operation: String, _ body: Data, path: String?) {
        lock.withLock {
            byOperation[operation, default: []].append(body)
            pathsByOperation[operation, default: []].append(path ?? "")
        }
    }
    func last(_ operation: String) -> [String: Any]? {
        guard let data = lock.withLock({ byOperation[operation]?.last }), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func lastPath(_ operation: String) -> String? {
        lock.withLock { pathsByOperation[operation]?.last }
    }
}

/// A frame source the test scripts: what is held before the bind, and what
/// the wait resolves to. Records the floor the flow asked for.
@MainActor
private final class CannedFrames: StateFrameSource {
    var held: Components.Schemas.StateFrame?
    var next: Components.Schemas.StateFrame?
    private(set) var askedFloor: Date??
    /// The id the wait asked about, and every id the floor was read for, so a
    /// test can prove the flow followed the hub's id rather than the proposed
    /// one.
    private(set) var askedId: String?
    private(set) var heldAskedIds: [String] = []
    func heldFrame(for deviceId: String) -> Components.Schemas.StateFrame? {
        heldAskedIds.append(deviceId)
        return held
    }
    func nextFrame(
        for deviceId: String, newerThan floor: Date?, timeout: Duration
    ) async -> Components.Schemas.StateFrame? {
        askedId = deviceId
        askedFloor = .some(floor)
        return next
    }
}

/// Stops one call mid-flight so a test can act underneath it: the stub calls
/// `arrive()` and parks there, the test waits for the arrival, does its thing,
/// then `release()`s. Same shape as `Started` in HistoryModelTests, with the
/// release half added.
private actor Gate {
    private var arrived = false
    private var released = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arrive() async {
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
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
/// The hub matched an existing row for this channel and kept its id, which is
/// not the id the sheet proposed. `Store.bind_device` matches on
/// (driver_type, channel), so this is the ordinary re-adopt case.
private let boundElsewhere = #"{"device_id":"left-fixture","created":false,"driver_type":"pca9685","channel":"3"}"#
private let granted = #"{"id":"6f1c2a4e-0000-4000-8000-000000000001","target":"pca9685-3","duty":0.5,"expires_at":"2026-09-04T18:00:05Z","expires_in_s":5.0,"transition":"snap"}"#
private let renamed = #"{"device_id":"pca9685-3","display_name":"Left fixture"}"#

/// A hub that answers every call the flow can make; `overrideStatus` lets one
/// test refuse the pulse, and `beforeBind` lets one test hold the bind open
/// long enough to cancel underneath it.
private func hub(
    log: CallLog, bodies: Bodies, bind: String, overrideStatus: Int = 200,
    beforeBind: (@Sendable () async -> Void)? = nil
) -> HubClient {
    HubClient(
        hub: anyHub, tokens: MemoryCredentials(token: "refresh"),
        transport: StubTransport { operation, request, body in
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            await log.record(operation)
            bodies.record(operation, body, path: request.path)
            if operation == "bindDevice", let beforeBind { await beforeBind() }
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
        _ client: HubClient, frames: CannedFrames, timeout: Duration = .seconds(1),
        pulseSettle: Duration = .milliseconds(1)
    ) -> IdentifyFlow {
        IdentifyFlow(
            client: client, frames: frames, request: request(), channel: "3",
            rebuildTimeout: timeout, pulseSettle: pulseSettle
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

    @Test("the bind's device id is what the wait, the pulse and the rename target")
    func hubDeviceIdWinsOnTheHappyPath() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        let flow = makeFlow(hub(log: log, bodies: bodies, bind: boundElsewhere), frames: frames)

        _ = try await flow.start()
        await flow.settle()
        #expect(flow.deviceId == "left-fixture", "the hub matched a row that keeps its own id")
        #expect(flow.phase == .answer)
        // Waiting on the proposed id would wait for a frame that never comes:
        // the rebuild publishes under the id the registry holds.
        #expect(frames.askedId == "left-fixture")
        #expect(frames.heldAskedIds == ["pca9685-3", "left-fixture"], "the floor is re-read for the real id")
        #expect(bodies.last("createOverride")?["target"] as? String == "left-fixture")

        flow.chooseToName()
        await flow.name("Left fixture")
        #expect(flow.phase == .named)
        #expect(bodies.lastPath("renameDevice") == "/api/v1/devices/left-fixture")
    }

    @Test("the bind's device id is what Not this one unbinds")
    func hubDeviceIdWinsOnLeave() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        let flow = makeFlow(hub(log: log, bodies: bodies, bind: boundElsewhere), frames: frames)

        _ = try await flow.start()
        await flow.settle()
        flow.leave()
        await flow.settle()
        // Unbinding the proposed id 404s into .alreadyUnbound, which reads as
        // success: the phase would say .left while the rejected channel stayed
        // adopted.
        #expect(flow.phase == .left)
        #expect(bodies.lastPath("unbindDevice") == "/api/v1/devices/left-fixture")
        #expect(await log.count(of: "forgetDevice") == 0, "created: false; the row predates this flow")
    }

    @Test("a cancel during the bind unbinds once the bind lands, and never pulses")
    func leaveDuringTheBind() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        let gate = Gate()
        let flow = makeFlow(
            hub(
                log: log, bodies: bodies, bind: boundCreated,
                beforeBind: { await gate.arrive() }
            ),
            frames: frames
        )

        let started = Task { try await flow.start() }
        await gate.waitForArrival()
        // Cancel with the bind still in flight: `running` is nil here, so the
        // flow has to remember the intent rather than act on an id and a
        // created flag it does not have yet.
        flow.leave()
        await gate.release()
        _ = try await started.value
        await flow.settle()

        #expect(flow.phase == .left)
        #expect(await log.count(of: "createOverride") == 0, "cancel means nobody is watching the tank")
        #expect(await log.count(of: "unbindDevice") == 1, "the row must not stay adopted after Cancel")
        #expect(await log.count(of: "forgetDevice") == 1, "this flow created the row")
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

    @Test("not this one while the pulse is live releases the hold, then unbinds and forgets")
    func notThisOneDuringPulse() async throws {
        let log = CallLog(), bodies = Bodies()
        let frames = CannedFrames()
        frames.next = try stateFrame(emittedAt: "2026-09-04T17:00:20.000000Z")
        // A pulseSettle long enough that leave() lands while the hold is
        // still up: the running task is parked in the granted branch's
        // sleep, not yet at .answer.
        let flow = makeFlow(
            hub(log: log, bodies: bodies, bind: boundCreated), frames: frames,
            pulseSettle: .seconds(30)
        )
        _ = try await flow.start()
        // Not `phase == .pulsing`: that flips the instant pulse() starts,
        // before the hold has actually landed. Poll the finer signal so
        // leave() races a genuinely active hold, not one still in flight.
        var spins = 0
        while !flow.hasActiveHold {
            await Task.yield()
            spins += 1
            if spins > 100_000 {
                Issue.record("the hold never landed; phase is \(flow.phase)")
                return
            }
        }
        flow.leave()
        await flow.settle()
        #expect(flow.phase == .left, "the cancelled pulse must not leak a .failed phase over leave()'s .left")
        #expect(await log.count(of: "releaseOverride") == 1)
        #expect(await log.operations.suffix(3) == ["releaseOverride", "unbindDevice", "forgetDevice"])
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
