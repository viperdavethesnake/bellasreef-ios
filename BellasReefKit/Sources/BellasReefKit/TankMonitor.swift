// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Observation

/// Live tank state, assembled from the stream.
///
/// Owns reconnection, because the transport deliberately does not: `frames`
/// returns when the socket ends, and deciding whether that deserves a retry —
/// and telling the operator honestly while it is down — is a UI concern, not a
/// socket one.
@MainActor
@Observable
public final class TankMonitor {

    /// What the Tank tab is allowed to claim.
    ///
    /// `disconnected` is a first-class state rather than "keep showing the last
    /// number". A stale reading presented as live is the failure mode that
    /// matters on a tank: it looks fine right up until it isn't.
    public enum Connection: Equatable, Sendable {
        case idle
        case connecting
        case live
        case disconnected(String)
        /// The hub sent something this build cannot decode — a pinned-contract
        /// mismatch, not a network problem, and it will not fix itself.
        case contractMismatch(String)
    }

    public private(set) var connection: Connection = .idle
    public private(set) var temperature: Components.Schemas.SensorReading?
    public private(set) var temperatureHistory: [Double] = []
    /// Latest state per actuator, keyed by id.
    public private(set) var channels: [String: Components.Schemas.StateFrame] = [:]
    public private(set) var lastFrameAt: Date?

    private let client: HubClient
    private let stream: StreamClient
    private var task: Task<Void, Never>?

    /// How many samples the sparkline keeps. ~25 minutes at the DS18B20's
    /// honest cadence; enough to see a trend, not enough to be a chart.
    private let historyLimit = 300

    public init(client: HubClient, stream: StreamClient) {
        self.client = client
        self.stream = stream
    }

    /// A reading older than this is not "live" any more.
    ///
    /// The DS18B20 takes ~831 ms per conversion and is polled every few
    /// seconds, so a minute of silence means something is wrong rather than
    /// merely slow.
    public static let stalenessThreshold: TimeInterval = 60

    public var isStale: Bool {
        guard let last = lastFrameAt else { return false }
        return Date().timeIntervalSince(last) > Self.stalenessThreshold
    }

    /// Safety tone for the status line.
    ///
    /// Red is reserved: a latched interlock only. A disconnected socket is
    /// amber, not red — losing the network is not a safety event, and the theme
    /// rule is that when red appears it means something.
    public var tone: HealthTone {
        if channels.values.contains(where: { $0.payload.latched == true }) { return .safety }
        switch connection {
        case .live where !isStale: return .allClear
        default: return .attention
        }
    }

    public var statusLine: String {
        if channels.values.contains(where: { $0.payload.latched == true }) {
            return "Interlock latched"
        }
        switch connection {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .live: return isStale ? "No data for a minute" : "All clear"
        case let .disconnected(why): return "Disconnected — \(why)"
        case let .contractMismatch(detail): return "App and hub disagree — \(detail)"
        }
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        Task { await stream.disconnect() }
        connection = .idle
    }

    private func run() async {
        // Backoff caps at 30s: a hub that is off for the evening should not be
        // hammered, and one that just restarted should be picked up quickly.
        var backoff: TimeInterval = 1

        while !Task.isCancelled {
            connection = .connecting
            do {
                let token = try await client.accessTokenNow()
                for try await frame in await stream.frames(accessToken: token) {
                    backoff = 1
                    apply(frame)
                }
                // The stream ended without throwing: a clean close from the hub.
                if !Task.isCancelled { connection = .disconnected("hub closed the stream") }
            } catch let error as StreamClient.StreamError {
                if case .undecodableFrame = error {
                    // Retrying will not help — the contracts differ.
                    connection = .contractMismatch(error.description)
                    return
                }
                connection = .disconnected(error.description)
            } catch let error as HubClient.ClientError {
                connection = .disconnected(error.description)
                if case .unauthorized = error { return }
            } catch {
                connection = .disconnected(error.localizedDescription)
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 30)
        }
    }

    private func apply(_ frame: StreamFrame) {
        lastFrameAt = Date()
        switch frame {
        case .ready:
            connection = .live
        case let .sensor(sensor):
            connection = .live
            guard sensor.payload.sensorType == "temp" else { return }
            // Only "ok" readings move the display. A fault must not quietly
            // become a number on screen.
            guard sensor.payload.quality == .ok, let value = sensor.payload.value else { return }
            temperature = sensor.payload
            temperatureHistory.append(value)
            if temperatureHistory.count > historyLimit {
                temperatureHistory.removeFirst(temperatureHistory.count - historyLimit)
            }
        case let .state(state):
            connection = .live
            channels[state.payload.actuatorId] = state
        }
    }
}
