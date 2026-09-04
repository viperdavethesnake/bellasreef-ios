// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation

/// Identify before adopt (C4, spec 2026-09-03).
///
/// Adopt a channel with no name, wait for hardware-io to rebuild it, pulse it
/// through the ordinary override path, and let the operator say whether the
/// right fixture lit. The order lives here, not in the sheet, so it is
/// testable against `StubTransport` and a canned `StateFrameSource`; the
/// sheet renders `phase` and calls the verbs.
///
/// Nothing here drives an unadopted channel: the pulse is a manual hold on a
/// device the hub has already registered with the full safety triple.
@MainActor
@Observable
public final class IdentifyFlow {
    /// The step a failure came from, which is what Retry repeats.
    public enum Step: Equatable, Sendable {
        case waitForHub
        case pulse
        case name
        case leave
    }

    public enum Phase: Equatable, Sendable {
        case choose
        /// Bound, waiting for the rebuild's startup frame.
        case adopting
        /// The hold is placed; the operator is watching the tank.
        case pulsing
        case answer
        case naming
        /// Named. The sheet dismisses and refreshes.
        case named
        /// Unbound (and forgotten if this flow created the row). The sheet
        /// dismisses and refreshes: hardware-io restarted on the way.
        case left
        case failed(reason: String, retry: Step)
    }

    /// Pinned by the spec. Duty clear of the 8 % floor and plainly visible;
    /// the 50 % row both silicons were metered at (1.654 V). Snap because the
    /// operator is standing at the tank. The server ends the hold.
    public static let pulseDuty = 0.50
    public static let pulseDurationS = 5.0
    /// Three times the measured hardware-io restart (about 15 s).
    public static let rebuildTimeout: Duration = .seconds(45)

    public private(set) var phase: Phase = .choose
    /// True once the hub holds a row for this channel that this flow bound.
    public private(set) var adopted = false
    /// From the bind. false means the hub matched a detached row that already
    /// carried a name and history; Not this one must not forget that row.
    public private(set) var created: Bool?
    /// The id every later call targets. Seeded from the proposed id, then
    /// replaced by the one the bind returned. `Store.bind_device` matches on
    /// (driver_type, channel) and hands back the existing row's id whatever
    /// the caller proposed, so a channel adopted under another id in an
    /// earlier session comes back under that id. Waiting, pulsing, renaming
    /// and unbinding against the proposed id would wait for a frame that
    /// never arrives, hold the wrong device, and unbind nothing.
    public private(set) var deviceId: String
    /// "PWM ch n", the number the tapped row shows.
    public let channelLabel: String

    private let client: HubClient
    private let frames: any StateFrameSource
    private let request: Components.Schemas.BindDeviceRequest
    private let timeout: Duration
    private let pulseSettle: Duration
    private var floor: Date?
    private var activeHoldId: String?
    private var running: Task<Void, Never>?
    /// True only while `client.bind` is in flight. `running` is nil then (the
    /// bind is awaited on the caller's task), so `leave()` cannot tell "no
    /// background step" from "the bind has not landed yet" without this.
    private var binding = false
    /// Set by a `leave()` that arrived while the bind was in flight. `start()`
    /// performs the leave once the bind lands, with the real device id and the
    /// created flag in hand.
    private var abandoned = false

    public init(
        client: HubClient,
        frames: any StateFrameSource,
        request: Components.Schemas.BindDeviceRequest,
        channel: String,
        rebuildTimeout: Duration = IdentifyFlow.rebuildTimeout,
        pulseSettle: Duration = .seconds(IdentifyFlow.pulseDurationS)
    ) {
        precondition(request.displayName == nil, "identify adopts nameless; the name comes last")
        self.client = client
        self.frames = frames
        self.request = request
        self.deviceId = request.deviceId
        self.channelLabel = "PWM ch \(channel)"
        self.timeout = rebuildTimeout
        self.pulseSettle = pulseSettle
    }

    /// Bind, then (on `.bound`) wait for the rebuild and pulse in the
    /// background. Any other outcome, or a thrown transport error, leaves the
    /// phase at `.choose` for the sheet's existing error rendering.
    public func start() async throws -> HubClient.BindOutcome {
        floor = frames.heldFrame(for: deviceId)?.payload.emittedAt
        phase = .adopting
        let outcome: HubClient.BindOutcome
        binding = true
        do {
            outcome = try await client.bind(request)
        } catch {
            binding = false
            // Nothing was adopted, so there is nothing for a pending leave to
            // undo; the sheet is back on its normal sections.
            abandoned = false
            phase = .choose
            throw error
        }
        binding = false
        guard case let .bound(id, created) = outcome else {
            abandoned = false
            phase = .choose
            return outcome
        }
        // The hub's id, not the proposed one: see `deviceId`.
        if id != deviceId {
            deviceId = id
            // The floor above was read for the proposed id, which is not the
            // id the frames arrive under. Re-read it: the rebuild is seconds
            // away, so anything held for this id right now is the retained
            // frame from its previous life, which is exactly the floor a
            // fresh startup frame has to clear.
            floor = frames.heldFrame(for: id)?.payload.emittedAt
        }
        adopted = true
        self.created = created
        if abandoned {
            // Cancel was tapped while the bind was in flight. Undo it now,
            // rather than pulsing a channel nobody is watching.
            abandoned = false
            run { await self.unbindAndMaybeForget() }
        } else {
            run { await self.waitThenPulse() }
        }
        return outcome
    }

    public func pulseAgain() {
        run { await self.pulse() }
    }

    public func chooseToName() {
        phase = .naming
    }

    public func name(_ name: String) async {
        phase = .naming
        do {
            try await client.rename(deviceId: deviceId, to: name)
            phase = .named
        } catch {
            phase = .failed(reason: HumanError.describe(error), retry: .name)
        }
    }

    /// Not this one, and Cancel while adopting. Ends a hold still inside its
    /// five seconds, unbinds, and forgets only a row this flow created.
    public func leave() {
        if binding {
            // The bind has not landed, so there is no id to unbind and no
            // created flag to guard the forget with. Record the intent;
            // start() carries it out the moment the bind returns.
            abandoned = true
            return
        }
        running?.cancel()
        run { await self.unbindAndMaybeForget() }
    }

    public func retry() {
        guard case let .failed(_, step) = phase else { return }
        switch step {
        case .waitForHub: run { await self.waitThenPulse() }
        case .pulse: run { await self.pulse() }
        case .name: phase = .naming
        case .leave: leave()
        }
    }

    // Internal, not private: the tests await the background step.
    func settle() async {
        await running?.value
    }

    // Internal, not private: `.pulsing` covers both "the hold was requested"
    // and "the hold landed and is sleeping out its duration" — a test that
    // wants leave() to land on a genuinely live hold (to exercise the
    // release-then-unbind path, not merely a hold still in flight) needs a
    // signal finer than `phase`.
    var hasActiveHold: Bool { activeHoldId != nil }

    private func run(_ step: @escaping @MainActor () async -> Void) {
        // One background step at a time. Without this, a double tap on Pulse
        // again drops the first task on the floor while it is still running
        // and posts a second override behind it.
        running?.cancel()
        running = Task { await step() }
    }

    private func waitThenPulse() async {
        phase = .adopting
        let frame = await frames.nextFrame(for: deviceId, newerThan: floor, timeout: timeout)
        if Task.isCancelled { return }
        guard frame != nil else {
            phase = .failed(
                reason: "The hub is still restarting. Retry waits for it again; the channel stays adopted.",
                retry: .waitForHub
            )
            return
        }
        await pulse()
    }

    private func pulse() async {
        phase = .pulsing
        do {
            let outcome = try await client.hold(
                target: deviceId, duty: Self.pulseDuty, durationS: Self.pulseDurationS,
                reason: "identify", transition: .snap
            )
            // leave() cancels this task and starts unbindAndMaybeForget()
            // concurrently; a hold() that resolves (granted or refused)
            // after that race must not overwrite the .left it is about to
            // write. Guard every phase write below the await, matching the
            // .granted branch's existing post-sleep check.
            if Task.isCancelled { return }
            switch outcome {
            case let .granted(view):
                activeHoldId = view.id
                // The server expires the hold; this only paces the sheet to
                // the answer step. A backgrounded app arrives there on return.
                try? await Task.sleep(for: pulseSettle)
                if Task.isCancelled { return }
                activeHoldId = nil
                phase = .answer
            case .clockUntrusted:
                phase = .failed(
                    reason: "The hub's clock is still syncing. Try Identify again in a moment.",
                    retry: .pulse
                )
            case .notCommandable:
                phase = .failed(reason: "The hub refused the pulse on this channel.", retry: .pulse)
            }
        } catch {
            // Same race, from the throwing side: a cancelled in-flight call
            // can surface as a generic transport error well after leave()
            // has already moved the flow to .left.
            if Task.isCancelled { return }
            phase = .failed(reason: HumanError.describe(error), retry: .pulse)
        }
    }

    private func unbindAndMaybeForget() async {
        do {
            if let holdId = activeHoldId {
                // Tolerated either way: 404 means the hold already expired.
                _ = try? await client.release(overrideId: holdId)
                activeHoldId = nil
            }
            if adopted {
                _ = try await client.unbind(deviceId: deviceId)
                if created == true {
                    _ = try await client.forget(deviceId: deviceId)
                }
            }
            phase = .left
        } catch {
            phase = .failed(reason: HumanError.describe(error), retry: .leave)
        }
    }
}
