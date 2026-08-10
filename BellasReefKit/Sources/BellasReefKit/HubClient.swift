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
        /// Someone must approve from an already-paired client.
        case pending(requestId: String, pollAfter: Int)
        /// Every client is revoked and no window is open — nobody can approve.
        case needsRecoveryCLI
    }

    public enum ClientError: Error, CustomStringConvertible {
        case unexpected(String)
        case unauthorized
        /// The hub understood the request and refused it, with a reason worth
        /// showing verbatim.
        case rejected(String)

        public var description: String {
            switch self {
            case let .unexpected(detail): detail
            case .unauthorized: "the hub rejected this credential"
            case let .rejected(reason): reason
            }
        }
    }

    public let hub: Hub
    private let client: Client
    private let tokens: TokenStore

    private let tokenProvider: TokenProvider

    private var accessToken: String?
    private var accessExpiry: Date?

    public init(hub: Hub, tokens: TokenStore = TokenStore()) {
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
            transport: URLSessionTransport(),
            middlewares: [BearerAuthMiddleware(token: { try await provider.token() })]
        )
        provider.resolve = { [self] in try await accessTokenNow() }
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
        case .unauthorized: throw ClientError.unauthorized
        case .unprocessableContent: throw ClientError.unexpected("the hub rejected the query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("sensors returned \(statusCode)")
        }
    }

    /// Name a device, or pass `nil` to go back to the raw id.
    public func rename(deviceId: String, to name: String?) async throws {
        switch try await client.renameDevice(
            path: .init(deviceId: deviceId), body: .json(.init(displayName: name))
        ) {
        case .ok: return
        case .unauthorized: throw ClientError.unauthorized
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
        case .unauthorized: throw ClientError.unauthorized
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
                    deviceId: row.deviceId,
                    bound: row.bound == .max ? "max" : "min",
                    value: row.raisedValue,
                    threshold: row.threshold,
                    unit: row.unit,
                    raisedAt: row.raisedAt
                )
            }
        case .unauthorized:
            throw ClientError.unauthorized
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the alerts query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("alerts returned \(statusCode)")
        }
    }

    // MARK: Pairing

    public func pair(clientName: String) async throws -> PairingOutcome {
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
                requestId: pending.requestId,
                pollAfter: pending.pollAfterS
            )
        case .forbidden:
            return .needsRecoveryCLI
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("pair returned \(statusCode)")
        default:
            throw ClientError.unexpected("pair returned an unhandled response")
        }
    }

    // MARK: Tokens

    /// A valid access token, minted if the cached one is missing or stale.
    ///
    /// Refreshed a minute early: a token that expires mid-request is a failure
    /// the operator sees, and a minute of margin costs nothing.
    public func accessTokenNow() async throws -> String {
        if let token = accessToken, let expiry = accessExpiry,
           expiry.timeIntervalSinceNow > 60 {
            return token
        }
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
            throw ClientError.unauthorized
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

    /// How many clients the hub still considers live.
    ///
    /// Used to decide whether signing out is the *last* way in. The caller is
    /// authenticated, so it is one of them: a count of 1 means this device is
    /// the only one, and revoking it needs hub access to undo.
    public func liveClientCount() async throws -> Int {
        switch try await client.listClients() {
        case let .ok(response):
            return try response.body.json.filter { $0.revokedAt == nil }.count
        case .unauthorized: throw ClientError.unauthorized
        case .unprocessableContent: throw ClientError.unexpected("the hub rejected the query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("clients returned \(statusCode)")
        }
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
