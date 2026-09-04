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
    public let deviceId: String
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

    public init(
        client: HubClient,
        frames: any StateFrameSource,
        request: Components.Schemas.BindDeviceRequest,
        channel: String,
        rebuildTimeout: Duration = IdentifyFlow.rebuildTimeout,
        pulseSettle: Duration = .seconds(5)
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
        do {
            outcome = try await client.bind(request)
        } catch {
            phase = .choose
            throw error
        }
        guard case let .bound(_, created) = outcome else {
            phase = .choose
            return outcome
        }
        adopted = true
        self.created = created
        run { await self.waitThenPulse() }
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

    private func run(_ step: @escaping @MainActor () async -> Void) {
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
            switch try await client.hold(
                target: deviceId, duty: Self.pulseDuty, durationS: Self.pulseDurationS,
                reason: "identify", transition: .snap
            ) {
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
