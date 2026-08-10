// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.bellasreef.app", category: "tank")

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

    /// What the probe is saying, including when it is saying nothing good.
    ///
    /// Design brief §7.2: a faulted sensor shows *fault*, never its last good
    /// number. Modelling that as a state rather than an optional is what makes
    /// it impossible to render the old value by accident — there is no last
    /// value to reach for once this becomes `.faulted`.
    public enum Probe: Equatable, Sendable {
        case waiting
        case reading(celsius: Double, sensorId: String, at: Date)
        case faulted(sensorId: String, at: Date)

        public var sensorId: String? {
            switch self {
            case .waiting: nil
            case let .reading(_, id, _), let .faulted(id, _): id
            }
        }

        public var observedAt: Date? {
            switch self {
            case .waiting: nil
            case let .reading(_, _, at), let .faulted(_, at): at
            }
        }
    }

    /// An open threshold breach, as the banner renders it.
    public struct Alert: Equatable, Sendable, Identifiable {
        public let deviceId: String
        public let bound: String
        public let value: Double
        public let threshold: Double
        public let unit: String
        public let raisedAt: Date

        /// Stable across updates so SwiftUI does not re-animate a banner that
        /// merely refreshed. One breach per bound per device is the invariant
        /// the hub's partial unique index enforces, so this is unique.
        public var id: String { "\(deviceId)/\(bound)" }

        public var isHigh: Bool { bound == "max" }
    }

    public private(set) var connection: Connection = .idle
    public private(set) var probe: Probe = .waiting
    public private(set) var temperatureHistory: [Double] = []
    /// Latest state per actuator, keyed by id.
    public private(set) var channels: [String: Components.Schemas.StateFrame] = [:]
    public private(set) var alerts: [Alert] = []
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
        guard let last = probe.observedAt else { return false }
        return Date().timeIntervalSince(last) > Self.stalenessThreshold
    }

    /// Safety tone for the status line.
    ///
    /// Red is reserved: a latched interlock only. A disconnected socket is
    /// amber, not red — losing the network is not a safety event, and the theme
    /// rule is that when red appears it means something. A threshold breach is
    /// amber too: the tank is out of range, which is not the same as an
    /// actuator having latched itself off.
    public var tone: HealthTone {
        if channels.values.contains(where: { $0.payload.latched == true }) { return .safety }
        if !alerts.isEmpty { return .attention }
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
        case .live:
            if case .faulted = probe { return "Sensor fault" }
            if !alerts.isEmpty { return alerts.count == 1 ? "1 alert" : "\(alerts.count) alerts" }
            return isStale ? "No data for a minute" : "All clear"
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
                // Alerts are published on core pub/sub with no replay, so a
                // breach that started while this app was backgrounded is not on
                // the stream. Seeding from REST is the only way a reconnecting
                // client learns the tank is currently out of range.
                await seedAlerts()
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

    private func seedAlerts() async {
        // A failure here is not worth surfacing to the operator: the socket is
        // about to open and the temperature will still render. It is worth
        // logging, though — a silently empty banner and a genuinely quiet tank
        // look identical, which is the same trap the metrics gauge set on the
        // hub side.
        do {
            alerts = try await client.activeAlerts()
        } catch {
            log.error("could not seed alerts: \(String(describing: error))")
        }
    }

    private func apply(_ frame: StreamFrame) {
        lastFrameAt = Date()
        switch frame {
        case .ready:
            connection = .live
        case let .sensor(sensor):
            connection = .live
            apply(sensor.payload)
        case let .state(state):
            connection = .live
            channels[state.payload.actuatorId] = state
        case let .alert(alert):
            connection = .live
            apply(alert.payload)
        case .unknown:
            // A frame kind this build predates. Ignored on purpose — see
            // StreamClient.decode.
            connection = .live
        }
    }

    private func apply(_ reading: Components.Schemas.SensorReading) {
        guard reading.sensorType == "temp" else { return }
        let observedAt = reading.emittedAt

        switch reading.quality {
        // `nil` means the field was omitted, and the schema declares its default
        // as "ok". Treating absence as a fault would be stricter but wrong: it
        // would blank the display for a reading the hub considers good.
        case .ok, .none:
            guard let value = reading.value else { return }
            // The hub speaks Celsius and only Celsius. Storing the raw wire
            // value keeps conversion at the render edge, so history never
            // contains a mix of units.
            guard reading.unit == "degC" else { return }
            probe = .reading(celsius: value, sensorId: reading.sensorId, at: observedAt)
            temperatureHistory.append(value)
            if temperatureHistory.count > historyLimit {
                temperatureHistory.removeFirst(temperatureHistory.count - historyLimit)
            }
        case .fault:
            probe = .faulted(sensorId: reading.sensorId, at: observedAt)
        case .stale:
            // Neither a good reading nor a failure. Left as-is so the age stamp
            // ages naturally rather than being reset by a re-presented value.
            break
        }
    }

    private func apply(_ alert: Components.Schemas.SensorAlert) {
        let entry = Alert(
            deviceId: alert.deviceId,
            bound: alert.bound == .max ? "max" : "min",
            value: alert.value,
            threshold: alert.threshold,
            unit: alert.unit,
            raisedAt: alert.emittedAt
        )
        alerts.removeAll { $0.id == entry.id }
        if alert.state == .breach {
            alerts.append(entry)
        }
        alerts.sort { $0.raisedAt > $1.raisedAt }
    }
}
