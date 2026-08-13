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

        var request = request
        request.headerFields[.authorization] = "Bearer \(try await token())"
        return try await next(request, body, baseURL)
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
