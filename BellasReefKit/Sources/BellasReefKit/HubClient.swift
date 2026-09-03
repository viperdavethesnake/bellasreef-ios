// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// REST access to one hub.
///
/// A thin wrapper around the **generated** client: it owns the token lifecycle
/// and nothing else. Every request and response type here comes from the spec.
public actor HubClient {
    public enum PairingOutcome: Sendable {
        /// The hub had never paired anything, or a recovery window was open.
        case granted(refreshToken: String, clientId: String)
        /// Someone must approve, by typing this request's code into a device
        /// that is already paired.
        case pending(PendingPairing)
        /// Every client is revoked and no window is open — nobody can approve.
        case needsRecoveryCLI
        /// Setup mode, and the code was missing or wrong. 422 — but the
        /// 3.7.0 contract carries no reason body for that response (it also
        /// covers a rejected `client_name` on the plain flow, which shares
        /// the same status and shape), so this is a distinct case rather
        /// than a thrown `.rejected(reason)`: the caller supplies its own
        /// copy, never one read off the wire. Only returned when this call
        /// carried a `setupCode` — see `pair(clientName:setupCode:)`.
        case codeRejected
        /// Too many failed setup-code attempts, globally throttled. 429 —
        /// only reachable when this call carried a `setupCode`.
        case throttled
    }

    /// The 202 body, whole.
    ///
    /// `pairingCode` is the point of the screen this drives: six digits the
    /// operator reads off this device and types into the one already paired.
    /// `expiresIn` is here because the screen used to hardcode "five minutes"
    /// while discarding the number the hub had just sent it.
    public struct PendingPairing: Sendable, Equatable {
        public let requestId: String
        public let pairingCode: String
        public let pollAfter: Int
        public let expiresIn: Int

        public init(requestId: String, pairingCode: String, pollAfter: Int, expiresIn: Int) {
            self.requestId = requestId
            self.pairingCode = pairingCode
            self.pollAfter = pollAfter
            self.expiresIn = expiresIn
        }
    }

    /// Every documented ending of `GET /api/v1/pair/{request_id}`.
    ///
    /// Distinct cases rather than an optional token, because each one needs
    /// different words and a different way out. Collapsing 403, 404 and 410
    /// into "failed" is how a waiting device ends up telling the operator to
    /// keep waiting for a decision that has already been made.
    public enum PollOutcome: Sendable, Equatable {
        /// 200 — approved, and this is the only time the credential is sent.
        case granted(refreshToken: String, clientId: String)
        /// 202 — nobody has typed the code yet.
        case stillPending
        /// 403 — denied on the hub.
        case denied
        /// 404 — the hub has no such request.
        case unknown
        /// 410 — expired, or the credential was already collected. One
        /// credential per approval, so a second poll after a successful one
        /// lands here too.
        case gone
    }

    /// Every documented ending of `POST /api/v1/pair/claim`.
    public enum ClaimOutcome: Sendable, Equatable {
        /// 200 — the code matched a pending request and it is now approved.
        case approved(requestId: String)
        /// 404 — no pending request carries that code.
        case noSuchCode
        /// 409 — the request is no longer pending.
        case notPending
        /// 422 — not six digits.
        case malformed
    }

    public enum ClientError: Error, CustomStringConvertible {
        case unexpected(String)
        case unauthorized
        /// The hub understood the request and refused it, with a reason worth
        /// showing verbatim.
        case rejected(String)
        /// Too many failed setup-code attempts, globally throttled. 429 on a
        /// call that carried no `setupCode` — kept out of `.rejected` so a
        /// caller can tell "wait and try again" apart from a flat refusal
        /// without inspecting the string (review ruling, 2026-08-15, round
        /// 2: `submitWithoutCode()` used to catch both as `.rejected` and
        /// show the wrong copy for a throttle).
        case throttled(String)
        /// The Keychain could not hold a credential. Raised *before* pairing,
        /// so nothing has been spent when the operator sees it.
        case credentialStoreUnusable(String)

        public var description: String {
            switch self {
            case let .unexpected(detail): detail
            case .unauthorized: "the hub rejected this credential"
            case let .rejected(reason): reason
            case let .throttled(reason): reason
            case let .credentialStoreUnusable(detail):
                "this device cannot store a credential — \(detail)"
            }
        }
    }

    public let hub: Hub
    private let client: Client
    private let tokens: any CredentialStore

    /// Fired when the hub *proves* this device's credential dead: `mintToken`
    /// rejected the refresh token. A 401 on any other call is not proof — that
    /// only means the access token went stale, and the next mint decides.
    ///
    /// This is the REST twin of `TankMonitor.onCredentialRejected`, and it
    /// exists because the monitor's copy turned out to be unreachable on a
    /// revoked device: its stream, authenticated at handshake, stays up, so
    /// the only wiring to the pairing screen ran through a reconnect that
    /// never happened — while every REST call failed as an inline error.
    private var credentialRejectedHandler: (@Sendable () -> Void)?

    public func notifyCredentialRejected(_ handler: @escaping @Sendable () -> Void) {
        credentialRejectedHandler = handler
    }

    private let tokenProvider: TokenProvider

    private var accessToken: String?
    private var accessExpiry: Date?

    /// `transport` is injectable so the auth paths can be tested at all.
    ///
    /// It was hardcoded to `URLSessionTransport()`, which is why the twenty
    /// tests in this package touched everything except pairing: there was no
    /// way to answer a request without a hub on the LAN.
    public init(
        hub: Hub,
        tokens: any CredentialStore = TokenStore(),
        transport: any ClientTransport = URLSessionTransport()
    ) {
        self.hub = hub
        self.tokens = tokens

        // The middleware needs a token, getting a token needs this actor, and
        // this actor is not initialised yet. The box breaks the cycle: it is
        // handed to the middleware now and given its resolver below, once
        // `self` is fully formed.
        let provider = TokenProvider()
        self.tokenProvider = provider
        self.client = Client(
            serverURL: hub.baseURL,
            configuration: Configuration(dateTranscoder: FractionalSecondsDateTranscoder()),
            transport: transport,
            middlewares: [
                BearerAuthMiddleware(
                    token: { try await provider.token() },
                    freshToken: { try await provider.freshToken() }
                )
            ]
        )
        provider.resolve = { [self] in try await accessTokenNow() }
        provider.resolveFresh = { [self] in try await freshAccessTokenNow() }
    }

    // MARK: Discovery

    /// Unauthenticated. Renders the connect screen before any commitment.
    public func info() async throws -> Components.Schemas.Info {
        switch try await client.info() {
        case let .ok(response):
            return try response.body.json
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("info returned \(statusCode)")
        }
    }

    // MARK: Devices

    /// Every registered sensor, with its name and alert band.
    public func sensors() async throws -> [Components.Schemas.DeviceView] {
        switch try await client.listSensors() {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent: throw ClientError.unexpected("the hub rejected the query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("sensors returned \(statusCode)")
        }
    }

    /// Every registered device, sensors and actuators alike.
    ///
    /// The Tank tab needs this for `role`: a state frame says what an actuator
    /// is doing and never what it is for, so without the registry every PWM
    /// channel on the hub renders under one heading regardless of whether it
    /// drives an LED or a dosing pump.
    public func devices() async throws -> [Components.Schemas.DeviceView] {
        switch try await client.listDevices() {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the devices query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("devices returned \(statusCode)")
        }
    }

    // MARK: Audit

    /// The audit trail: who did what, and when.
    ///
    /// `category` filters server-side when given; `nil` asks for everything.
    /// The hub does not document result ordering, so callers that need newest
    /// first must sort the page themselves rather than trust the wire order.
    public func audit(
        limit: Int? = nil, category: String? = nil
    ) async throws -> [Components.Schemas.AuditEvent] {
        switch try await client.listAudit(query: .init(limit: limit, category: category)) {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the audit query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("audit returned \(statusCode)")
        }
    }

    // MARK: Capabilities and adoption

    /// What the hardware can offer, and what has been claimed. Tier one of
    /// the registry: nothing here is a device until an operator binds it.
    public func capabilities() async throws -> [Components.Schemas.CapabilityView] {
        switch try await client.listCapabilities() {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the capabilities query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("capabilities returned \(statusCode)")
        }
    }

    /// What each chip last reported about itself (`GET /api/v1/hardware`) —
    /// the Hardware leaf's per-board second line. Register-level facts, not
    /// capabilities: a capability is what channels a board offers, this is
    /// what the chip's own registers said when hardware-io brought it up.
    public func hardware() async throws -> [Components.Schemas.ChipStateView] {
        switch try await client.listHardware() {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the hardware query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("hardware returned \(statusCode)")
        }
    }

    /// The hub machine's own vitals (`GET /api/v1/hub-status`) — the Hub
    /// status leaf's data source. `nil` is "not yet": a fresh boot that has
    /// not published its first snapshot, or a pre-4.3.0 hub with no such
    /// endpoint — either way something the leaf renders as unavailable, not
    /// as a failure.
    public func hubStatus() async throws -> Components.Schemas.HubStatusView? {
        switch try await client.getHubStatus() {
        case let .ok(response): return try response.body.json
        case .notFound: return nil
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the hub-status query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("hub-status returned \(statusCode)")
        }
    }

    /// Every documented ending of `POST /api/v1/devices`. Distinct cases
    /// because each needs different words and a different way out — the 409
    /// in particular means the list on screen is stale, not that the operator
    /// did anything wrong.
    public enum BindOutcome: Sendable, Equatable {
        /// 200. `created: false` is match-before-create: the channel already
        /// carried a device, which was adopted in place under its own id.
        case bound(deviceId: String, created: Bool)
        /// 404 — the channel is no longer announced.
        case channelGone
        /// 409 — another device claimed the channel since the list loaded.
        case alreadyBound
        /// 422 — the role is not legal for this device.
        case roleNotLegal
    }

    public func bind(
        _ request: Components.Schemas.BindDeviceRequest
    ) async throws -> BindOutcome {
        switch try await client.bindDevice(body: .json(request)) {
        case let .ok(response):
            let bound = try response.body.json
            return .bound(deviceId: bound.deviceId, created: bound.created)
        case .notFound: return .channelGone
        case .conflict: return .alreadyBound
        case .unprocessableContent: return .roleNotLegal
        case .unauthorized: throw credentialWasRejected()
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("bind returned \(statusCode)")
        }
    }

    /// Every documented ending of `DELETE /api/v1/devices/{device_id}`.
    public enum UnbindOutcome: Sendable, Equatable {
        case unbound
        /// 404 — unknown, or already unbound. Either way the channel is free.
        case alreadyUnbound
    }

    public func unbind(deviceId: String) async throws -> UnbindOutcome {
        switch try await client.unbindDevice(path: .init(deviceId: deviceId)) {
        case .noContent: return .unbound
        case .notFound: return .alreadyUnbound
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the device id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("unbind returned \(statusCode)")
        }
    }

    /// Every documented ending of `POST /api/v1/devices/{device_id}/readopt`.
    ///
    /// The Detached section's "Re-add" (ruled 2026-08-15): `unbind` keeps the
    /// row and its binding on purpose, and this is what makes that worth
    /// doing rather than merely quiet — the operator gets the *same* device
    /// back, name and history intact, instead of re-binding through `bind`
    /// and hoping the proposed id is the one that lands.
    public enum ReadoptOutcome: Sendable, Equatable {
        /// 200 — reattached, with its old name, thresholds and history.
        case readopted(Components.Schemas.DeviceView)
        /// 404 — unknown, or not detached.
        case notDetached
        /// 409 — its channel is now held by another adopted device.
        case channelHeld
    }

    public func readopt(deviceId: String) async throws -> ReadoptOutcome {
        switch try await client.readoptDevice(path: .init(deviceId: deviceId)) {
        case let .ok(response): return .readopted(try response.body.json)
        case .notFound: return .notDetached
        case .conflict: return .channelHeld
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the device id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("readopt returned \(statusCode)")
        }
    }

    /// Every documented ending of `POST /api/v1/devices/{device_id}/forget`.
    ///
    /// The Detached section's "Clear" — deleting a detached row for good.
    /// Distinct from the parameterless `forget()` below, which clears this
    /// device's own stored credential; this one asks the hub to delete
    /// someone else's device row.
    public enum ForgetDeviceOutcome: Sendable, Equatable {
        case forgotten
        /// 404 — unknown.
        case unknown
        /// 409 — still adopted; unbind it first.
        case stillAdopted
    }

    public func forget(deviceId: String) async throws -> ForgetDeviceOutcome {
        switch try await client.forgetDevice(path: .init(deviceId: deviceId)) {
        case .noContent: return .forgotten
        case .notFound: return .unknown
        case .conflict: return .stillAdopted
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the device id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("forget returned \(statusCode)")
        }
    }

    /// Name a device, or pass `nil` to go back to the raw id.
    public func rename(deviceId: String, to name: String?) async throws {
        switch try await client.renameDevice(
            path: .init(deviceId: deviceId), body: .json(.init(displayName: name))
        ) {
        case .ok: return
        case .unauthorized: throw credentialWasRejected()
        case .notFound: throw ClientError.unexpected("the hub does not know that device")
        case .unprocessableContent: throw ClientError.rejected("that name was rejected")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("rename returned \(statusCode)")
        }
    }

    /// Set or clear the alert band.
    ///
    /// A 422 is surfaced as `.rejected` with the hub's own explanation rather
    /// than a generic failure: the hub is the authority on which bands are
    /// usable, and paraphrasing "the clear margin is wider than half the band"
    /// into "invalid input" throws away the only part the operator can act on.
    public func setThresholds(
        deviceId: String, minimum: Double?, maximum: Double?, clearMargin: Double?
    ) async throws {
        // The generator orders init parameters alphabetically, not in schema
        // order, so the labels are load-bearing here.
        let body = Components.Schemas.AlertThresholds(
            clearMargin: clearMargin, maximum: maximum, minimum: minimum
        )
        switch try await client.setThresholds(path: .init(deviceId: deviceId), body: .json(body)) {
        case .ok: return
        case .unauthorized: throw credentialWasRejected()
        case .notFound: throw ClientError.unexpected("the hub does not know that device")
        case .conflict: throw ClientError.rejected("thresholds can only be set on a sensor")
        case let .unprocessableContent(response):
            throw ClientError.rejected(Self.explain(response))
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("thresholds returned \(statusCode)")
        }
    }

    /// Pull the human-readable half out of FastAPI's validation envelope.
    private static func explain(
        _ response: Operations.SetThresholds.Output.UnprocessableContent
    ) -> String {
        guard let detail = try? response.body.json.detail, let first = detail.first else {
            return "the hub rejected those thresholds"
        }
        // Pydantic prefixes validator failures with "Value error, ". The
        // sentence after it is written for a person; the prefix is framework
        // plumbing and reads as noise on a settings screen.
        let message = first.msg
        let prefix = "Value error, "
        return message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
    }

    // MARK: Overrides

    /// Every documented ending of `POST /api/v1/overrides`.
    ///
    /// The 503 is its own case rather than a thrown `.rejected` — an override
    /// IS a deadline, and the Lighting tab must render "the hub's clock is
    /// not trusted yet" as its own quiet state, not as a generic failure the
    /// operator would retry into an identical result (spec Feature 2, plan
    /// 2026-08-15 Global Constraints).
    public enum HoldOutcome: Sendable, Equatable {
        /// 200 — the hold is live now. Carries the whole created override
        /// (mirrors `readopt`'s whole-`DeviceView` return): `.id` is what
        /// `release` needs, and `.duty`/`.expiresInS` let the card show the
        /// hold immediately rather than waiting on the next state frame.
        case granted(Components.Schemas.OverrideView)
        /// 409 — the target does not accept commands (`observe_only`
        /// authority; device-classes.md §2.3). The command never reached a
        /// component that "knew better" and dropped it — it was refused at
        /// the boundary, and the operator should be told that plainly rather
        /// than as a generic rejection.
        case notCommandable
        /// 503 — clock not synchronised; a deadline computed from a clock
        /// chrony is about to step is not the duration the operator asked
        /// for. Pinned copy renders this, not `HumanError`.
        case clockUntrusted
    }

    /// How the hub moves a light to a held level and back — the operator's
    /// choice per hold (backend spec 2026-08-17). `snap` is one step on
    /// arrival AND on release/expiry; `ramp` is the hub's global slew both
    /// ways. Hand-written wrapper over the generated
    /// `OverrideRequest.TransitionPayload` so the view never touches a
    /// generated enum name — the mapping below is the only place they meet.
    public enum HoldTransition: String, CaseIterable, Sendable, Equatable {
        case snap
        case ramp

        /// "Snap" / "Ramp" — the operator-facing word for this transition.
        /// Hoisted here (deferred-minors review fold) so it lives in the one
        /// place next to the type it describes: `LightingView`'s card and
        /// `TankView`'s Equipment row both render holds off the same wire
        /// concept and used to carry their own private copy of this switch,
        /// which is exactly the kind of thing that drifts one small edit at
        /// a time.
        public var label: String {
            switch self {
            case .snap: "Snap"
            case .ramp: "Ramp"
            }
        }

        var payload: Components.Schemas.OverrideRequest.TransitionPayload {
            switch self {
            case .snap: .snap
            case .ramp: .ramp
            }
        }

        public init(_ payload: Components.Schemas.OverrideContext.TransitionPayload) {
            switch payload {
            case .snap: self = .snap
            case .ramp: self = .ramp
            }
        }

        public init(_ payload: Components.Schemas.OverrideView.TransitionPayload) {
            switch payload {
            case .snap: self = .snap
            case .ramp: self = .ramp
            }
        }
    }

    /// Every hold live on the hub right now (`GET /api/v1/overrides`).
    ///
    /// The Lighting tab never needs this: it learns a hold from the state
    /// frame's `override`, arriving on a socket it is already holding open. A
    /// caller with no stream — the Release app intent, woken by Shortcuts or
    /// by a Live Activity button, with nothing subscribed — has no other way
    /// to learn the id that ends a hold. `OverrideView.target` is the device
    /// id, so the row for one light is a filter away.
    ///
    /// The hub does not document result ordering, so a caller that cares
    /// sorts the page itself.
    public func overrides() async throws -> [Components.Schemas.OverrideView] {
        switch try await client.listOverrides() {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the overrides query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("overrides returned \(statusCode)")
        }
    }

    public func hold(
        target: String, duty: Double, durationS: Double, reason: String,
        transition: HoldTransition
    ) async throws -> HoldOutcome {
        switch try await client.createOverride(
            body: .json(.init(
                durationS: durationS, duty: duty, reason: reason, target: target,
                transition: transition.payload
            ))
        ) {
        case let .ok(response): return .granted(try response.body.json)
        case .conflict: return .notCommandable
        case .serviceUnavailable: return .clockUntrusted
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected that hold")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("hold returned \(statusCode)")
        }
    }

    /// Every documented ending of `DELETE /api/v1/overrides/{override_id}`.
    public enum ReleaseOutcome: Sendable, Equatable {
        case released
        /// 404 — unknown, or already released. The hold is gone either way,
        /// same shape as `unbind`'s `.alreadyUnbound`.
        case alreadyReleased
    }

    /// `overrideId` is `HoldOutcome.granted`'s `.id` — the only field the
    /// generated `OverrideView`/`OverrideContext` shapes offer to identify a
    /// hold for release; there is no separate "handle". A caller reading the
    /// id off a live state frame's `override` (rather than off its own
    /// `hold` call) uses the same id, since both are the wire's
    /// `OverrideContext`/`OverrideView.id`.
    public func release(overrideId: String) async throws -> ReleaseOutcome {
        switch try await client.releaseOverride(path: .init(overrideId: overrideId)) {
        case .ok: return .released
        case .notFound: return .alreadyReleased
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected that override id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("release returned \(statusCode)")
        }
    }

    // MARK: Schedules

    /// The schedule library (`GET /api/v1/lighting/schedules`) — every
    /// curve, with the channels each is assigned to.
    public func schedules() async throws -> [Components.Schemas.ScheduleView] {
        switch try await client.listSchedules() {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the schedules query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("schedules returned \(statusCode)")
        }
    }

    /// Every documented ending of creating or replacing a schedule. One enum
    /// for both verbs because the editor's Save is one gesture — which verb
    /// ran is not something the operator should need different handling for.
    public enum ScheduleSaveOutcome: Sendable {
        /// 200 — the hub's copy, authoritative (times normalised, id set).
        case saved(Components.Schemas.ScheduleView)
        /// 409 — another schedule already has this name.
        case nameTaken
        /// 422 — the curve does not validate. Description-only on the wire,
        /// so no hub sentence to relay; the editor pre-validates with the
        /// same rules to make this near-unreachable.
        case curveRejected
        /// 404 — update only: the schedule was deleted under the editor.
        case unknownSchedule
    }

    public func createSchedule(
        _ request: Components.Schemas.ScheduleRequest
    ) async throws -> ScheduleSaveOutcome {
        switch try await client.createSchedule(body: .json(request)) {
        case let .ok(response): return .saved(try response.body.json)
        case .conflict: return .nameTaken
        case .unprocessableContent: return .curveRejected
        case .unauthorized: throw credentialWasRejected()
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("createSchedule returned \(statusCode)")
        }
    }

    public func updateSchedule(
        id: String, _ request: Components.Schemas.ScheduleRequest
    ) async throws -> ScheduleSaveOutcome {
        switch try await client.updateSchedule(
            path: .init(scheduleId: id), body: .json(request)
        ) {
        case let .ok(response): return .saved(try response.body.json)
        case .notFound: return .unknownSchedule
        case .conflict: return .nameTaken
        case .unprocessableContent: return .curveRejected
        case .unauthorized: throw credentialWasRejected()
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("updateSchedule returned \(statusCode)")
        }
    }

    /// Every documented ending of `DELETE /api/v1/lighting/schedules/{id}`.
    public enum ScheduleDeleteOutcome: Sendable, Equatable {
        case deleted
        /// 409 — still assigned to a channel; unassign it first (the hub's
        /// ON DELETE RESTRICT, the forgetDevice lesson pre-applied).
        case stillAssigned
        /// 404 — already gone.
        case unknown
    }

    public func deleteSchedule(id: String) async throws -> ScheduleDeleteOutcome {
        switch try await client.deleteSchedule(path: .init(scheduleId: id)) {
        case .noContent: return .deleted
        case .conflict: return .stillAssigned
        case .notFound: return .unknown
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the schedule id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("deleteSchedule returned \(statusCode)")
        }
    }

    /// Every documented ending of pointing a channel at a schedule. Assign
    /// replaces whatever was assigned — one schedule per channel is the
    /// hub's data model, so there is no "already assigned" conflict case.
    public enum AssignOutcome: Sendable {
        /// 200 — echoes the schedule, `assignedChannels` freshly including
        /// this channel.
        case assigned(Components.Schemas.ScheduleView)
        /// 409 — the channel is registered observe_only and accepts no
        /// commands (same meaning as `HoldOutcome.notCommandable`).
        case notCommandable
        /// 404 — the schedule was deleted under the picker.
        case unknownSchedule
    }

    public func assignSchedule(
        channelId: String, scheduleId: String
    ) async throws -> AssignOutcome {
        switch try await client.assignSchedule(
            path: .init(channelId: channelId),
            body: .json(.init(scheduleId: scheduleId))
        ) {
        case let .ok(response): return .assigned(try response.body.json)
        case .conflict: return .notCommandable
        case .notFound: return .unknownSchedule
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the channel id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("assignSchedule returned \(statusCode)")
        }
    }

    /// Every documented ending of clearing a channel's schedule.
    public enum UnassignOutcome: Sendable, Equatable {
        case unassigned
        /// 404 — nothing was assigned; already the state the operator asked
        /// for, so callers treat it as success with different words.
        case nothingAssigned
    }

    public func unassignSchedule(channelId: String) async throws -> UnassignOutcome {
        switch try await client.unassignSchedule(path: .init(channelId: channelId)) {
        case .ok: return .unassigned
        case .notFound: return .nothingAssigned
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the channel id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("unassignSchedule returned \(statusCode)")
        }
    }

    // MARK: History

    /// Downsampled history for the window, with alert episodes.
    ///
    /// `buckets` is a *request*, not a promise — the hub caps it. Downsampling
    /// happens there precisely so a day of five-second samples never crosses
    /// the network.
    public func history(
        from start: Date, to end: Date, buckets: Int = 240
    ) async throws -> Components.Schemas.HistoryView {
        switch try await client.history(
            query: .init(start: start, end: end, buckets: buckets)
        ) {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent: throw ClientError.rejected("the hub refused that window")
        case .serviceUnavailable:
            throw ClientError.rejected("the hub has no telemetry store configured")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("history returned \(statusCode)")
        }
    }

    // MARK: Alerts

    /// Currently-open threshold breaches.
    ///
    /// The reconnect path. Alerts travel on core pub/sub with no replay, so a
    /// client that was backgrounded through a breach would otherwise show an
    /// all-clear tank that is actually out of range.
    public func activeAlerts() async throws -> [TankMonitor.Alert] {
        switch try await client.listAlerts() {
        case let .ok(response):
            return try response.body.json.active.map { row in
                TankMonitor.Alert(
                    kind: row.alertClass == .silence ? .silence : .threshold,
                    deviceId: row.deviceId,
                    bound: row.bound.map { $0 == .max ? "max" : "min" },
                    value: row.raisedValue,
                    threshold: row.threshold,
                    unit: row.unit,
                    raisedAt: row.raisedAt,
                    lastReadingAt: row.lastReadingAt
                )
            }
        case .unauthorized:
            throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the alerts query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("alerts returned \(statusCode)")
        }
    }

    // MARK: Pairing

    /// auth.md §2 step 3.
    ///
    /// The Keychain is probed first, and a failure there throws before the
    /// request is sent. The hub issues one credential per TOFU grant or
    /// recovery window and spends the window doing it, so discovering at *store*
    /// time that this device cannot keep a secret means the credential is gone
    /// and the only way back is SSH. The probe costs one Keychain round trip and
    /// moves that discovery to the side of the line where nothing is spent.
    public func pair(clientName: String, setupCode: String? = nil) async throws -> PairingOutcome {
        do {
            try tokens.probe()
        } catch let storeError as TokenStore.StoreError {
            throw ClientError.credentialStoreUnusable(storeError.description)
        } catch {
            // Whatever a non-production `CredentialStore` throws (a test
            // fake, say) is not a sentence anyone authored — keep the case's
            // "could not store a credential" framing rather than leaking the
            // raw error text.
            throw ClientError.credentialStoreUnusable("could not be probed")
        }

        let output = try await client.pair(
            body: .json(.init(clientName: clientName, setupCode: setupCode))
        )
        switch output {
        case let .ok(response):
            let granted = try response.body.json
            return .granted(
                refreshToken: granted.refreshToken,
                clientId: granted.clientId
            )
        case let .accepted(response):
            let pending = try response.body.json
            return .pending(
                PendingPairing(
                    requestId: pending.requestId,
                    pairingCode: pending.pairingCode,
                    pollAfter: pending.pollAfterS,
                    expiresIn: pending.expiresInS
                )
            )
        case .forbidden:
            return .needsRecoveryCLI
        case .conflict:
            // The recovery window was spent by someone else between /info and
            // this call. Named rather than generic: the operator's next move is
            // to run `bellasreef pair` again, not to retry this button.
            throw ClientError.rejected(
                "another device used the recovery window first — open a new one on the hub"
            )
        case .unprocessableContent:
            // 3.7.0: 422 has no body, and covers two different refusals that
            // share the one status code — a rejected `client_name` (plain
            // flow) or a missing/wrong `setup_code` (setup-code flow). Which
            // one it was is decided by what this call sent, not by anything
            // the hub sends back (controller ruling, 2026-08-15: do not
            // parse an undeclared body).
            guard setupCode != nil else {
                throw ClientError.rejected("the hub would not accept that name")
            }
            return .codeRejected
        case .tooManyRequests:
            // 3.7.0: only a setup-code attempt is rate-limited, so this
            // should only be reachable when `setupCode` was supplied — but
            // "should" is not "is", and a code-less 429 must not silently
            // become an outcome case the plain flow's exhaustive switch has
            // no honest handling for. Symmetric with the 422 arm just
            // above: thrown for the code-less caller, returned as an
            // outcome only when this call carried a `setupCode`. Thrown as
            // `.throttled`, not `.rejected` — a caller that also sends
            // code-less calls (the setup screen's own fire escape) needs to
            // tell a throttle apart from a flat refusal without parsing the
            // reason string, and `.rejected` and `.throttled` render the
            // same word-for-word text either way.
            guard setupCode != nil else {
                throw ClientError.throttled("too many failed setup-code attempts — wait and try again")
            }
            return .throttled
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("pair returned \(statusCode)")
        }
    }

    /// auth.md §2 step 3, the waiting half. Unauthenticated by design — this
    /// device has no credential yet, which is the whole point of asking.
    public func poll(requestId: String) async throws -> PollOutcome {
        switch try await client.pollPairing(path: .init(requestId: requestId)) {
        case let .ok(response):
            let granted = try response.body.json
            return .granted(refreshToken: granted.refreshToken, clientId: granted.clientId)
        case .accepted: return .stillPending
        case .forbidden: return .denied
        case .notFound: return .unknown
        case .gone: return .gone
        case .unprocessableContent:
            throw ClientError.unexpected("the hub could not read that request id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("poll returned \(statusCode)")
        }
    }

    /// auth.md §2 step 3a — approve by typing the six digits the new device
    /// shows.
    ///
    /// The code is a *selector*, not a credential: the bearer token on this
    /// call is what gates approval, so only an already-paired device can
    /// approve anything. That is why there is no attempt counter here.
    public func claim(code: String) async throws -> ClaimOutcome {
        switch try await client.claimPairing(body: .json(.init(code: code))) {
        case let .ok(response): return .approved(requestId: try response.body.json.requestId)
        case .unauthorized: throw credentialWasRejected()
        case .notFound: return .noSuchCode
        case .conflict: return .notPending
        case .unprocessableContent: return .malformed
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("claim returned \(statusCode)")
        }
    }

    // MARK: Tokens

    /// One mint at a time. The actor suspends across `await mintToken`, so
    /// without this a second caller finds no cached token and starts a second
    /// mint — observed live as two `token.minted` audit rows 38 µs apart.
    private var mintInFlight: Task<String, any Error>?

    /// A valid access token, minted if the cached one is missing or stale.
    ///
    /// Refreshed a minute early: a token that expires mid-request is a failure
    /// the operator sees, and a minute of margin costs nothing.
    public func accessTokenNow() async throws -> String {
        if let token = accessToken, let expiry = accessExpiry,
           expiry.timeIntervalSinceNow > 60 {
            return token
        }
        if let inFlight = mintInFlight { return try await inFlight.value }

        let work = Task { try await self.mintFresh() }
        mintInFlight = work
        defer { mintInFlight = nil }
        return try await work.value
    }

    /// A token that is *known* fresh: the cache is dropped first, so the hub
    /// is consulted. This is what turns a data-call 401 into an answer — a
    /// stale token gets replaced, a revoked device gets `mintToken`'s
    /// rejection and the handler fires. Joins an in-flight mint rather than
    /// stacking a second one: that mint is fresh by definition.
    public func freshAccessTokenNow() async throws -> String {
        accessToken = nil
        accessExpiry = nil
        return try await accessTokenNow()
    }

    private func mintFresh() async throws -> String {
        guard let refresh = try tokens.load() else { throw ClientError.unauthorized }

        let output = try await client.mintToken(body: .json(.init(refreshToken: refresh)))
        switch output {
        case let .ok(response):
            let minted = try response.body.json
            accessToken = minted.accessToken
            accessExpiry = Date().addingTimeInterval(TimeInterval(minted.expiresIn))
            return minted.accessToken
        case .unauthorized:
            // Revoked, or the hub was rebuilt. Forget the credential rather
            // than retrying against something that will never accept it.
            try? tokens.clear()
            credentialRejectedHandler?()
            throw credentialWasRejected()
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("token returned \(statusCode)")
        default:
            throw ClientError.unexpected("token returned an unhandled response")
        }
    }

    public func store(refreshToken: String) throws {
        try tokens.save(refreshToken, hub: hub.name)
    }

    public func isPaired() -> Bool {
        (try? tokens.load()) != nil
    }

    public func forget() throws {
        accessToken = nil
        accessExpiry = nil
        try tokens.clear()
    }

    /// The clients the hub still trusts, newest contact first.
    ///
    /// Returns the rows rather than a count. It used to fetch this list and
    /// immediately reduce it to `.count`, which is why the app could tell the
    /// operator they were the last device standing and could not tell them
    /// which other devices existed — and `revokeClient` had nothing to hang
    /// off. The count is one `.count` away at the call site.
    ///
    /// Revoked rows are dropped here. They are what keeps `paired_client_count`
    /// honest on the hub and they are litter on a screen: a revoked phone is
    /// not a device you can revoke again.
    public func clients() async throws -> [Components.Schemas.Client] {
        switch try await client.listClients() {
        case let .ok(response):
            return try response.body.json
                .filter { $0.revokedAt == nil }
                .sorted { ($0.lastSeenAt ?? $0.createdAt) > ($1.lastSeenAt ?? $1.createdAt) }
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent: throw ClientError.unexpected("the hub rejected the query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("clients returned \(statusCode)")
        }
    }

    /// Revoke another device. auth.md §2 step 5 — any paired device may do it.
    ///
    /// Immediate, not `exp`-bounded: the hub checks liveness on every
    /// authenticated route and at the WebSocket handshake, so the revoked
    /// device stops working on its next request rather than in fifteen minutes.
    public func revoke(clientId: String) async throws {
        switch try await client.revokeClient(path: .init(clientId: clientId)) {
        case .ok: return
        case .unauthorized: throw credentialWasRejected()
        case .notFound:
            throw ClientError.rejected("the hub does not know that device, or it is already revoked")
        case .unprocessableContent:
            throw ClientError.unexpected("the hub could not read that client id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("revoke returned \(statusCode)")
        }
    }

    /// A 401 means the cached access token is worthless *now*.
    ///
    /// Dropping it here is what turns a 401 into one bad request instead of up
    /// to fourteen minutes of them: refresh was proactive only, sixty seconds
    /// before expiry, so a clock step, a hub restart or a regenerated signing
    /// key left the app resending a dead token until the clock said otherwise.
    /// The *refresh* token is untouched — only `mintToken` rejecting it proves
    /// that one is dead.
    private func credentialWasRejected() -> ClientError {
        accessToken = nil
        accessExpiry = nil
        return .unauthorized
    }

    /// Sign out: revoke on the hub first, then forget locally.
    ///
    /// Order matters. Clearing the credential first would leave no way to
    /// authenticate the revocation, and the hub would keep counting this device
    /// as a live approver forever — which is the lockout this exists to stop.
    /// If the hub cannot be reached the local credential is still cleared,
    /// because a sign-out that silently does nothing is worse; the caller is
    /// told so it can say the hub still has a stale record.
    public func signOut() async throws {
        defer { try? forget() }
        switch try await client.revokeSelf() {
        case .ok: return
        case .unauthorized:
            // Already revoked, or the credential expired. Either way this device
            // is not an approver, which is the outcome we wanted.
            return
        case .unprocessableContent:
            return
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("sign-out returned \(statusCode)")
        }
    }
}
