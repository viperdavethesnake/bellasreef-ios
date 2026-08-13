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
        /// The Keychain could not hold a credential. Raised *before* pairing,
        /// so nothing has been spent when the operator sees it.
        case credentialStoreUnusable(String)

        public var description: String {
            switch self {
            case let .unexpected(detail): detail
            case .unauthorized: "the hub rejected this credential"
            case let .rejected(reason): reason
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
    public func pair(clientName: String) async throws -> PairingOutcome {
        do {
            try tokens.probe()
        } catch {
            throw ClientError.credentialStoreUnusable("\(error)")
        }

        let output = try await client.pair(
            body: .json(.init(clientName: clientName))
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
            throw ClientError.rejected("the hub would not accept that name")
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
