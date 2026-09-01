// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

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

@Suite("ScheduleLibrary")
@MainActor
struct ScheduleLibraryTests {

    @Test("refresh loads and sorts by name; failure is its own state with the message kept")
    func refreshStates() async {
        let library = ScheduleLibrary(client: stub { _ in
            (200, json(#"""
                [{"id": "b", "name": "Zebra", "zone": "UTC", "anchor": "clock",
                  "points": [{"at": "08:00:00", "duty": 0.0}, {"at": "20:00:00", "duty": 0.5}],
                  "assigned_channels": []},
                 {"id": "a", "name": "Alpha", "zone": "UTC", "anchor": "clock",
                  "points": [{"at": "08:00:00", "duty": 0.0}, {"at": "20:00:00", "duty": 0.5}],
                  "assigned_channels": ["pi-pwm-0"]}]
                """#))
        })
        await library.refresh()
        #expect(library.state == .loaded)
        #expect(library.schedules.map(\.name) == ["Alpha", "Zebra"])
        #expect(library.schedule(assignedTo: "pi-pwm-0")?.name == "Alpha")
        #expect(library.schedule(assignedTo: "pi-pwm-1") == nil)

        let failing = ScheduleLibrary(client: stub { _ in (500, nil) })
        await failing.refresh()
        guard case .failed = failing.state else {
            Issue.record("expected .failed, got \(failing.state)")
            return
        }
    }

    @Test("a successful mutation re-reads the library — the hub is the authority")
    func mutationRefreshes() async throws {
        let calls = CallCounter()
        let library = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await calls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "deleteSchedule")
            return (204, nil)
        })
        _ = try await library.delete(id: "6f1e4e2a-1111-4222-8333-444455556666")
        #expect(await calls.count == 1)
    }

    @Test("delete: a 404 (already gone) re-reads too — a ghost row should vanish")
    func deleteUnknownRefreshes() async throws {
        let calls = CallCounter()
        let library = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await calls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "deleteSchedule")
            return (404, nil)
        })
        let outcome = try await library.delete(id: "6f1e4e2a-1111-4222-8333-444455556666")
        #expect(outcome == .unknown)
        #expect(await calls.count == 1)
    }

    @Test("assign: a refusal does not re-read — the hub's copy did not change")
    func assignRefusalDoesNotRefresh() async throws {
        // Pins the gate the backlog flagged as implemented-but-untested: a
        // widened `if case .assigned` (say, refreshing on every outcome)
        // would spend a round trip re-reading a library the hub just said it
        // did not touch — and this fence is what would catch the widening.
        let calls = CallCounter()
        let library = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await calls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "assignSchedule")
            return (409, nil)
        })
        let outcome = try await library.assign(
            channelId: "pi-pwm-0", scheduleId: "6f1e4e2a-1111-4222-8333-444455556666"
        )
        guard case .notCommandable = outcome else {
            Issue.record("expected .notCommandable, got \(outcome)")
            return
        }
        #expect(await calls.count == 0)
    }

    @Test("create: a refusal does not re-read — the hub's copy did not change")
    func createRefusalDoesNotRefresh() async throws {
        let request = Components.Schemas.ScheduleRequest(
            name: "Reef day",
            points: [.init(at: "08:00:00", duty: 0.0), .init(at: "20:00:00", duty: 0.6)],
            zone: "UTC"
        )

        let nameTakenCalls = CallCounter()
        let nameTaken = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await nameTakenCalls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "createSchedule")
            return (409, nil)
        })
        guard case .nameTaken = try await nameTaken.create(request) else {
            Issue.record("expected .nameTaken")
            return
        }
        #expect(await nameTakenCalls.count == 0)

        let curveRejectedCalls = CallCounter()
        let curveRejected = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await curveRejectedCalls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "createSchedule")
            return (422, nil)
        })
        guard case .curveRejected = try await curveRejected.create(request) else {
            Issue.record("expected .curveRejected")
            return
        }
        #expect(await curveRejectedCalls.count == 0)
    }

    @Test("update: a refusal does not re-read — the hub's copy did not change")
    func updateRefusalDoesNotRefresh() async throws {
        let request = Components.Schemas.ScheduleRequest(
            name: "Reef day",
            points: [.init(at: "08:00:00", duty: 0.0), .init(at: "20:00:00", duty: 0.6)],
            zone: "UTC"
        )
        let id = "6f1e4e2a-1111-4222-8333-444455556666"

        let nameTakenCalls = CallCounter()
        let nameTaken = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await nameTakenCalls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "updateSchedule")
            return (409, nil)
        })
        guard case .nameTaken = try await nameTaken.update(id: id, request) else {
            Issue.record("expected .nameTaken")
            return
        }
        #expect(await nameTakenCalls.count == 0)

        let curveRejectedCalls = CallCounter()
        let curveRejected = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await curveRejectedCalls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "updateSchedule")
            return (422, nil)
        })
        guard case .curveRejected = try await curveRejected.update(id: id, request) else {
            Issue.record("expected .curveRejected")
            return
        }
        #expect(await curveRejectedCalls.count == 0)

        let unknownCalls = CallCounter()
        let unknown = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await unknownCalls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "updateSchedule")
            return (404, nil)
        })
        guard case .unknownSchedule = try await unknown.update(id: id, request) else {
            Issue.record("expected .unknownSchedule")
            return
        }
        #expect(await unknownCalls.count == 0)
    }

    @Test("unassign: a 404 (nothing assigned) re-reads too — a stuck checkmark self-heals")
    func unassignNothingRefreshes() async throws {
        let calls = CallCounter()
        let library = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await calls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "unassignSchedule")
            return (404, nil)
        })
        let outcome = try await library.unassign(channelId: "pi-pwm-0")
        #expect(outcome == .nothingAssigned)
        #expect(await calls.count == 1)
    }
}

private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
