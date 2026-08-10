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

        public var description: String {
            switch self {
            case let .unexpected(detail): detail
            case .unauthorized: "the hub rejected this credential"
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
}
