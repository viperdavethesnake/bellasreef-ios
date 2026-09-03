// Bella's Reef iOS — closed source.

import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Reads the filename out of a `Content-Disposition` header.
///
/// Not a general RFC 6266 parser. It handles the two forms a server might
/// plausibly send for this endpoint — `filename="x.csv"` and `filename=x.csv`
/// — and deliberately declines the RFC 5987 `filename*=UTF-8''…` form rather
/// than half-implementing a percent/charset decoder: returning `nil` there
/// falls back to `ExportFilename.build`, which is exact.
public enum ContentDisposition {

    /// The filename, or `nil` when the header is absent, names nothing, or
    /// names something that would not be a safe file name.
    public static func filename(from header: String?) -> String? {
        guard let header else { return nil }

        for parameter in header.split(separator: ";").dropFirst() {
            let halves = parameter.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            // Exact match, lowercased: `filename*` must not answer here, and
            // it does not, because the key is compared whole.
            guard halves[0].trimmingCharacters(in: .whitespaces).lowercased() == "filename" else {
                continue
            }

            var value = halves[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            // The value is about to become a path in the temporary directory
            // and it came off the network. Reducing it to a last path
            // component is what stops it naming anywhere else. This hub's
            // device ids are `[a-z0-9_-]{1,64}` and could not produce a
            // separator, so this guards a case that cannot happen from *this*
            // server — which is the only kind of guard worth having on a
            // filename.
            let name = (value as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            return name
        }
        return nil
    }
}

/// Carries one response's `Content-Disposition` back to the call that wanted
/// it.
///
/// The 4.4.0 spec describes the header on `historyExport` in prose but does
/// not declare it as a response header, so swift-openapi-generator emits no
/// `Ok.Headers` for the 200 and the value is dropped before any call site can
/// see it. The alternatives were to hand-write the request — forbidden here,
/// the client is generated — or to ignore the hub's own name for the file. A
/// middleware reading one header off the raw response is the smallest thing
/// that does neither.
///
/// **Deleting this is a backend change:** declare `Content-Disposition` in
/// the 200's `headers` and the generator hands `response.headers.contentDisposition`
/// to `HubClient` directly.
///
/// Opt-in via a task local, so the middleware writes only into the call that
/// installed a sink. `UniversalClient` invokes middlewares inline in the
/// caller's task (`for middleware in middlewares.reversed()` around a plain
/// `await`), so the local is visible from `intercept` and two exports running
/// at once cannot cross wires.
final class ResponseDispositionSink: @unchecked Sendable {
    @TaskLocal static var active: ResponseDispositionSink?

    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// See `ResponseDispositionSink`.
struct ContentDispositionMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        // Outermost in `HubClient`'s middleware list — `middlewares[0]` wraps
        // the rest — so this observes whatever `BearerAuthMiddleware`
        // finally returns, including the response to its retry after a 401,
        // rather than the 401 itself.
        if let sink = ResponseDispositionSink.active {
            sink.value = response.headerFields[.contentDisposition]
        }
        return (response, responseBody)
    }
}
