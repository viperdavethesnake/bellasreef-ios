// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import OSLog

private let log = Logger(subsystem: "com.bellasreef.app", category: "stream")

/// A frame from `/api/v1/stream`.
///
/// The cases wrap **generated** types. Per the PRD v1.3 G3 footnote, the
/// transport below is hand-written because WebSockets are not expressible in
/// OpenAPI — but nothing here describes a frame's *shape*. If the backend
/// changes a field, this file stops compiling, which is the whole point.
public enum StreamFrame: Sendable {
    case ready(Components.Schemas.ReadyFrame)
    case state(Components.Schemas.StateFrame)
    case sensor(Components.Schemas.SensorFrame)
    case alert(Components.Schemas.AlertFrame)
    /// A frame kind this build does not know. Carried rather than thrown — see
    /// `decode(_:)`.
    case unknown(kind: String)
}

/// Hand-written WebSocket transport. Carries **no contract knowledge**.
///
/// Its entire job is: connect, authenticate with the first message, hand bytes
/// to the generated decoders, and reconnect with backoff. Decisions about what
/// a frame contains live in the generated types.
///
/// Authentication is the first message rather than a header or query parameter
/// — browsers cannot set headers on a WebSocket handshake, and a token in a URL
/// lands in access logs. The backend closes an unauthenticated socket after a
/// few seconds.
public actor StreamClient {
    public enum StreamError: Error, CustomStringConvertible {
        case notConnected
        case undecodableFrame(String)

        public var description: String {
            switch self {
            case .notConnected: "stream is not connected"
            case let .undecodableFrame(detail):
                // A frame we cannot decode means the client and hub disagree
                // about the contract — a pinned-spec problem, not a network one.
                "undecodable frame (client and hub contracts may differ): \(detail)"
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session

        let decoder = JSONDecoder()
        // The backend emits ISO-8601 with fractional seconds; .iso8601 alone
        // rejects those and every frame would fail to decode.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = formatter.date(from: raw) ?? plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "bad date: \(raw)")
            )
        }
        self.decoder = decoder
    }

    private var streamURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/api/v1/stream"
        return components.url!
    }

    /// Connect and authenticate. Yields frames until the socket closes.
    ///
    /// Reconnection is the caller's business: this returns when the stream
    /// ends, and `TankMonitor` decides whether that deserves a retry. Putting
    /// backoff here would bury "the hub is unreachable" inside a loop that
    /// looks like it is working.
    public func frames(accessToken: String) -> AsyncThrowingStream<StreamFrame, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let task = self.session.webSocketTask(with: self.streamURL)
                    await self.adopt(task)
                    task.resume()

                    let auth = try JSONEncoder().encode(["token": accessToken])
                    try await task.send(.string(String(decoding: auth, as: UTF8.self)))

                    while true {
                        let message = try await task.receive()
                        guard case let .string(text) = message else { continue }
                        continuation.yield(try self.decode(text))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func adopt(_ task: URLSessionWebSocketTask) {
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = task
    }

    public func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    /// Decode by `kind`, into generated types.
    nonisolated func decode(_ text: String) throws -> StreamFrame {
        let data = Data(text.utf8)
        struct Kind: Decodable { let kind: String }

        let kind: String
        do {
            kind = try decoder.decode(Kind.self, from: data).kind
        } catch {
            // The full decoder dump is for the log; the payload that reaches
            // the Tank status pill (via `.contractMismatch`, see
            // `TankMonitor.run()`) must stay one short phrase.
            log.error("frame missing 'kind' field: \(String(describing: error))")
            throw StreamError.undecodableFrame("frame missing a 'kind' field")
        }

        do {
            switch kind {
            case "ready":
                return .ready(try decoder.decode(Components.Schemas.ReadyFrame.self, from: data))
            case "state":
                return .state(try decoder.decode(Components.Schemas.StateFrame.self, from: data))
            case "sensor":
                return .sensor(try decoder.decode(Components.Schemas.SensorFrame.self, from: data))
            case "alert":
                return .alert(try decoder.decode(Components.Schemas.AlertFrame.self, from: data))
            default:
                // Forward compatibility, and a deliberate split from how the
                // spine behaves.
                //
                // On the NATS spine an unknown message is rejected loudly:
                // sender and receiver may be different hardware generations and
                // a misread dose is dangerous. This is not the spine. It is a
                // display stream, and refusing to render the tank temperature
                // because the hub also sent a frame type this build predates is
                // strictly worse than ignoring that frame.
                //
                // Genuine drift — a renamed field on a kind we *do* know — still
                // throws below, which is the property PRD G3 protects.
                return .unknown(kind: kind)
            }
        } catch let error as StreamError {
            throw error
        } catch {
            log.error("frame '\(kind)' failed to decode: \(String(describing: error))")
            throw StreamError.undecodableFrame(Self.humanDecodingPhrase(kind: kind, error: error))
        }
    }

    /// The frame `kind` and, where the failure names one, the field that was
    /// missing or wrong — never the decoder's own dump. That dump (coding
    /// paths, `CodingKeys`, `Debug description`) is exactly the shape
    /// `HumanError` exists to keep off a screen, and `.contractMismatch`
    /// renders this string directly rather than through `HumanError.describe`
    /// (which would erase the one useful detail: which field drifted).
    private static func humanDecodingPhrase(kind: String, error: any Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return "frame '\(kind)' could not be decoded"
        }
        switch decodingError {
        case let .keyNotFound(key, _):
            return "frame '\(kind)' missing '\(key.stringValue)'"
        case let .valueNotFound(_, context):
            let field = context.codingPath.last?.stringValue ?? "a field"
            return "frame '\(kind)' missing '\(field)'"
        case let .typeMismatch(_, context):
            let field = context.codingPath.last?.stringValue ?? "a field"
            return "frame '\(kind)' has the wrong type for '\(field)'"
        case .dataCorrupted:
            return "frame '\(kind)' is malformed"
        @unknown default:
            return "frame '\(kind)' could not be decoded"
        }
    }
}
