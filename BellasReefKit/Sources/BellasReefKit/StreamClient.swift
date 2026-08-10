// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation

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
            throw StreamError.undecodableFrame("no kind field: \(error)")
        }

        do {
            switch kind {
            case "ready":
                return .ready(try decoder.decode(Components.Schemas.ReadyFrame.self, from: data))
            case "state":
                return .state(try decoder.decode(Components.Schemas.StateFrame.self, from: data))
            case "sensor":
                return .sensor(try decoder.decode(Components.Schemas.SensorFrame.self, from: data))
            default:
                // Forward compatibility: a hub newer than this app may send a
                // kind we do not know. Surfacing it as an error beats silently
                // ignoring a frame that might have mattered.
                throw StreamError.undecodableFrame("unknown frame kind '\(kind)'")
            }
        } catch let error as StreamError {
            throw error
        } catch {
            throw StreamError.undecodableFrame("\(kind): \(error)")
        }
    }
}
