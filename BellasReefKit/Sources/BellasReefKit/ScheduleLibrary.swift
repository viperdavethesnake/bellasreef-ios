// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.bellasreef.app", category: "schedules")

/// The schedule library, hub-authoritative: every read renders the hub's
/// copy, and a mutation is followed by a re-read — rather than a local
/// patch — whenever the hub's answer implies our copy may be stale, not
/// only on the verb's own literal success. The hub normalises times and
/// owns `assigned_channels`, and two clients can edit at once, so a 404
/// on delete or unassign is as informative as the 2xx: it means the other
/// client already got there.
///
/// Separate from `DeviceCatalog` for the same reason that is separate from
/// `TankMonitor`: different clock. Schedules change when a person edits
/// them, not when a reading arrives.
@MainActor
@Observable
public final class ScheduleLibrary {

    public enum Load: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var state: Load = .idle
    public private(set) var schedules: [Components.Schemas.ScheduleView] = []

    private let client: HubClient

    public init(client: HubClient) {
        self.client = client
    }

    public func refresh() async {
        if schedules.isEmpty { state = .loading }
        do {
            schedules = try await client.schedules().sorted { $0.name < $1.name }
            state = .loaded
        } catch {
            log.error("could not load schedules: \(String(describing: error))")
            state = .failed(HumanError.describe(error))
        }
    }

    /// The schedule playing on a channel, if any — `assigned_channels` is
    /// the wire's side of the join, one schedule per channel.
    public func schedule(assignedTo channelId: String) -> Components.Schemas.ScheduleView? {
        schedules.first { $0.assignedChannels.contains(channelId) }
    }

    public func create(
        _ request: Components.Schemas.ScheduleRequest
    ) async throws -> HubClient.ScheduleSaveOutcome {
        let outcome = try await client.createSchedule(request)
        if case .saved = outcome { await refresh() }
        return outcome
    }

    public func update(
        id: String, _ request: Components.Schemas.ScheduleRequest
    ) async throws -> HubClient.ScheduleSaveOutcome {
        let outcome = try await client.updateSchedule(id: id, request)
        if case .saved = outcome { await refresh() }
        return outcome
    }

    /// Refreshes on `.deleted` and also on `.unknown` (404) — a ghost row
    /// the hub had already dropped should still vanish from our copy when
    /// the operator confirms deletion, not just when the delete itself did
    /// the dropping. The rule is refresh whenever the hub's answer implies
    /// our copy may be stale, not only on the verb's own literal success.
    public func delete(id: String) async throws -> HubClient.ScheduleDeleteOutcome {
        let outcome = try await client.deleteSchedule(id: id)
        if outcome == .deleted || outcome == .unknown { await refresh() }
        return outcome
    }

    public func assign(
        channelId: String, scheduleId: String
    ) async throws -> HubClient.AssignOutcome {
        let outcome = try await client.assignSchedule(channelId: channelId, scheduleId: scheduleId)
        if case .assigned = outcome { await refresh() }
        return outcome
    }

    /// Refreshes on `.unassigned` and also on `.nothingAssigned` (404) — a
    /// stuck checkmark from a divergence with another client self-heals
    /// instead of surviving the operator's own unassign. The rule is
    /// refresh whenever the hub's answer implies our copy may be stale, not
    /// only on the verb's own literal success.
    public func unassign(channelId: String) async throws -> HubClient.UnassignOutcome {
        let outcome = try await client.unassignSchedule(channelId: channelId)
        if outcome == .unassigned || outcome == .nothingAssigned { await refresh() }
        return outcome
    }
}
