// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.bellasreef.app", category: "devices")

/// What the hub knows about each device: its name, and its alert band.
///
/// Separate from `TankMonitor` because the two have different clocks. Readings
/// arrive on a socket several times a minute; names and thresholds change only
/// when a person edits them. Folding them together would mean re-fetching
/// configuration on every temperature sample.
@MainActor
@Observable
public final class DeviceCatalog {

    /// §7.1 states, made explicit rather than inferred from an empty array.
    public enum Load: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var state: Load = .idle
    public private(set) var sensors: [Components.Schemas.DeviceView] = []

    private let client: HubClient

    public init(client: HubClient) {
        self.client = client
    }

    /// The operator's name for a device, or the raw id when unnamed.
    ///
    /// One place, so "friendly name everywhere" is a property of the app rather
    /// than a habit each view has to remember. A view that wants the id asks
    /// for the id.
    public func name(for deviceId: String) -> String {
        sensors.first { $0.deviceId == deviceId }?.displayName ?? deviceId
    }

    public func device(_ deviceId: String) -> Components.Schemas.DeviceView? {
        sensors.first { $0.deviceId == deviceId }
    }

    public func refresh() async {
        if sensors.isEmpty { state = .loading }
        do {
            sensors = try await client.sensors().sorted { lhs, rhs in
                (lhs.displayName ?? lhs.deviceId) < (rhs.displayName ?? rhs.deviceId)
            }
            state = .loaded
        } catch {
            log.error("could not load devices: \(String(describing: error))")
            state = .failed("\(error)")
        }
    }

    public func rename(_ deviceId: String, to name: String?) async throws {
        try await client.rename(deviceId: deviceId, to: name)
        await refresh()
    }

    public func setThresholds(
        _ deviceId: String, minimum: Double?, maximum: Double?, clearMargin: Double?
    ) async throws {
        try await client.setThresholds(
            deviceId: deviceId, minimum: minimum, maximum: maximum, clearMargin: clearMargin
        )
        await refresh()
    }
}
