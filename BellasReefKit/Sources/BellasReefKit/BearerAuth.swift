// Bella's Reef iOS — closed source.

import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Attaches the bearer token to every generated request.
///
/// A middleware rather than a header parameter on each operation. The token is
/// a *security scheme* in the spec, so the generator does not put it in any
/// operation's signature — and it should not: an access token lives 15 minutes
/// and is minted on demand, so baking one into a client built at launch would
/// hand every later request an expired credential.
///
/// The closure is asked per request, which is what lets `HubClient` refresh
/// silently underneath without rebuilding the client.
struct BearerAuthMiddleware: ClientMiddleware {
    let token: @Sendable () async throws -> String
    /// Asked only after a 401: drops the cached token and mints. Throwing
    /// here (the mint itself was rejected) is the revocation signal — the
    /// request is not resent.
    let freshToken: @Sendable () async throws -> String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        // The unauthenticated endpoints are the ones a client uses *before* it
        // has a credential. Asking for a token here would throw on the connect
        // screen, which is the one screen that must work without one.
        let unauthenticated: Set<String> = ["info", "pair", "mintToken", "pollPairing", "healthz"]
        guard !unauthenticated.contains(operationID) else {
            return try await next(request, body, baseURL)
        }

        // Buffered so the request can be sent twice: an HTTPBody is a stream
        // and may be single-shot. Every authenticated request this client
        // makes is a small JSON document; the cap matches StubTransport's.
        let payload: Data? = if let body {
            try await Data(collecting: body, upTo: 1 << 20)
        } else {
            nil
        }

        var request = request
        request.headerFields[.authorization] = "Bearer \(try await token())"
        let (response, responseBody) = try await next(
            request, payload.map { HTTPBody($0) }, baseURL
        )
        guard response.status == .unauthorized else { return (response, responseBody) }

        // One retry, through a mint that is forced to consult the hub. A
        // stale access token comes back replaced; a revoked device's mint
        // throws inside `freshToken()` — and it has already fired the
        // rejection handler by the time it does. That throw is deliberately
        // not re-raised from here: `UniversalClient.send` wraps *any* error a
        // middleware throws in its own `ClientError` before a call site ever
        // sees it, which is a different type from `HubClient.ClientError` and
        // would break every `case .unauthorized` handler in `HubClient` that
        // is written and tested against ours. Falling back to the original
        // 401 sends the failure through that same already-correct path
        // instead, and the request is not sent again.
        guard let fresh = try? await freshToken() else { return (response, responseBody) }
        request.headerFields[.authorization] = "Bearer \(fresh)"
        return try await next(request, payload.map { HTTPBody($0) }, baseURL)
    }
}

/// Late-bound access to the token, so the middleware can be built before the
/// actor that mints it exists.
///
/// `@unchecked` with a lock: the resolver is written exactly once during
/// `HubClient.init` and read on every request thereafter, and the compiler
/// cannot see that ordering.
final class TokenProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var _resolve: (@Sendable () async throws -> String)?
    private var _resolveFresh: (@Sendable () async throws -> String)?

    var resolve: (@Sendable () async throws -> String)? {
        get { lock.withLock { _resolve } }
        set { lock.withLock { _resolve = newValue } }
    }

    var resolveFresh: (@Sendable () async throws -> String)? {
        get { lock.withLock { _resolveFresh } }
        set { lock.withLock { _resolveFresh = newValue } }
    }

    func token() async throws -> String {
        guard let resolve else {
            throw HubClient.ClientError.unexpected("no credential is available yet")
        }
        return try await resolve()
    }

    func freshToken() async throws -> String {
        guard let resolveFresh else {
            throw HubClient.ClientError.unexpected("no credential is available yet")
        }
        return try await resolveFresh()
    }
}
