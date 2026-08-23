// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit
import BellasReefAPI

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

private func stub(_ handler: @escaping @Sendable (String) async throws -> (Int, Data?)) -> HubClient {
    HubClient(
        hub: anyHub, tokens: MemoryCredentials(token: "refresh"),
        transport: StubTransport { operation, _, _ in
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            return try await handler(operation)
        }
    )
}

@Suite("Schedule wrappers")
struct ScheduleClientTests {

    private static let scheduleJSON = #"""
        {"id": "6f1e4e2a-1111-4222-8333-444455556666", "name": "Reef day",
         "zone": "America/Los_Angeles", "anchor": "clock",
         "points": [{"at": "08:00:00", "duty": 0.0}, {"at": "12:00:00", "duty": 0.6},
                    {"at": "20:00:00", "duty": 0.0}],
         "assigned_channels": ["pi-pwm-0"]}
        """#

    @Test("the list decodes points, zone and assignments")
    func listDecodes() async throws {
        let client = stub { operation in
            #expect(operation == "listSchedules")
            return (200, json("[\(Self.scheduleJSON)]"))
        }
        let schedules = try await client.schedules()
        #expect(schedules.count == 1)
        #expect(schedules[0].name == "Reef day")
        #expect(schedules[0].points.count == 3)
        #expect(schedules[0].points[0].at == "08:00:00")
        #expect(schedules[0].assignedChannels == ["pi-pwm-0"])
    }

    @Test("create: 200 carries the created schedule; 409 is a name collision, not an error")
    func createOutcomes() async throws {
        let created = stub { _ in (200, json(Self.scheduleJSON)) }
        let request = Components.Schemas.ScheduleRequest(
            name: "Reef day",
            points: [.init(at: "08:00:00", duty: 0.0), .init(at: "20:00:00", duty: 0.6)],
            zone: "America/Los_Angeles"
        )
        guard case let .saved(schedule) = try await created.createSchedule(request) else {
            Issue.record("expected .saved")
            return
        }
        #expect(schedule.name == "Reef day")

        let collided = stub { _ in (409, nil) }
        guard case .nameTaken = try await collided.createSchedule(request) else {
            Issue.record("expected .nameTaken")
            return
        }
    }

    @Test("update: 404 is its own case — the library on screen is stale")
    func updateUnknown() async throws {
        let client = stub { _ in (404, nil) }
        let request = Components.Schemas.ScheduleRequest(
            name: "Reef day",
            points: [.init(at: "08:00:00", duty: 0.0), .init(at: "20:00:00", duty: 0.6)]
        )
        guard case .unknownSchedule = try await client.updateSchedule(
            id: "6f1e4e2a-1111-4222-8333-444455556666", request
        ) else {
            Issue.record("expected .unknownSchedule")
            return
        }
    }

    @Test("delete: 409 means still assigned — unassign first, in the hub's own rule")
    func deleteStillAssigned() async throws {
        let client = stub { _ in (409, nil) }
        #expect(try await client.deleteSchedule(
            id: "6f1e4e2a-1111-4222-8333-444455556666") == .stillAssigned)
    }

    @Test("assign: 200 echoes the schedule; 409 is observe_only")
    func assignOutcomes() async throws {
        let granted = stub { operation in
            #expect(operation == "assignSchedule")
            return (200, json(Self.scheduleJSON))
        }
        guard case .assigned = try await granted.assignSchedule(
            channelId: "pi-pwm-0", scheduleId: "6f1e4e2a-1111-4222-8333-444455556666"
        ) else {
            Issue.record("expected .assigned")
            return
        }
        let refused = stub { _ in (409, nil) }
        guard case .notCommandable = try await refused.assignSchedule(
            channelId: "pi-pwm-0", scheduleId: "6f1e4e2a-1111-4222-8333-444455556666"
        ) else {
            Issue.record("expected .notCommandable")
            return
        }
    }

    @Test("unassign: 404 means nothing was assigned — already the state the operator wanted")
    func unassignNothing() async throws {
        let cleared = stub { _ in (200, json(#"{"unassigned": "6f1e4e2a-1111-4222-8333-444455556666"}"#)) }
        #expect(try await cleared.unassignSchedule(channelId: "pi-pwm-0") == .unassigned)
        let empty = stub { _ in (404, nil) }
        #expect(try await empty.unassignSchedule(channelId: "pi-pwm-0") == .nothingAssigned)
    }
}
