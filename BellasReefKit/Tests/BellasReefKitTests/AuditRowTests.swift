// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation
import Testing

@testable import BellasReefKit

/// UX review A8/A9: the audit log was not usable as a post-mortem record —
/// a raw client UUID as the row's identity, "1h ago" on six rows with no
/// recoverable order, and every override "started" with no "ended". These
/// pin the row's three lines: title with the device, actor as a name, time
/// as a clock time with the relative age beside it.
@Suite("Audit row")
struct AuditRowTests {
    @Test("an override ending says why, when the hub says why")
    func endedWithReason() {
        #expect(AuditPhrase.title(action: "override.released", deviceName: "Light 1", reason: "superseded")
                == "Hold on Light 1 ended — replaced by a new hold")
        #expect(AuditPhrase.title(action: "override.released", deviceName: "Light 1", reason: "expired")
                == "Hold on Light 1 ended — time ran out")
        #expect(AuditPhrase.title(action: "override.released", deviceName: "Light 1", reason: "lapsed")
                == "Hold on Light 1 ended — lapsed while the hub was down")
        #expect(AuditPhrase.title(action: "override.released", deviceName: "Light 1", reason: "manual")
                == "Hold on Light 1 released")
        #expect(AuditPhrase.title(action: "override.released", deviceName: nil, reason: nil)
                == "Hold ended")
        #expect(AuditPhrase.title(action: "override.created", deviceName: "Light 1", reason: nil)
                == "Hold on Light 1 started")
    }

    @Test("the device for an event: device_id first, then the payload's target")
    func subject() {
        #expect(AuditRow.subjectId(deviceId: "led-blue", payload: ["target": "other"]) == "led-blue")
        #expect(AuditRow.subjectId(deviceId: nil, payload: ["target": "led-blue"]) == "led-blue")
        #expect(AuditRow.subjectId(deviceId: nil, payload: [:]) == nil)
    }

    @Test("an actor that is a paired client shows its name; services show as themselves")
    func actor() {
        let clients = ["ad981038-62ba-48e7-a2f8-b43fafc04f78": "iPhone A252"]
        #expect(AuditRow.actorName("ad981038-62ba-48e7-a2f8-b43fafc04f78", clients: clients) == "iPhone A252")
        #expect(AuditRow.actorName("api", clients: clients) == "hub")
        #expect(AuditRow.actorName("control-engine", clients: clients) == "engine")
        #expect(AuditRow.actorName("bellasreef-cli", clients: clients) == "hub CLI")
        #expect(AuditRow.actorName("hardware-io", clients: clients) == "hardware")
        // An unknown UUID is still shortened rather than dumped whole.
        #expect(AuditRow.actorName("3b8dc3b2-9997-41c6-9a9d-b7a981877e93", clients: clients) == "client 3b8dc3b2")
    }

    @Test("time is a clock time with the age beside it; older than today carries the date")
    func when() {
        let now = ISO8601DateFormatter().date(from: "2026-08-18T20:00:00Z")!
        let tz = TimeZone(identifier: "UTC")!
        let anHourAgo = now.addingTimeInterval(-3600)
        #expect(AuditRow.when(anHourAgo, now: now, timeZone: tz) == "19:00 · 1h ago")
        let yesterday = now.addingTimeInterval(-26 * 3600)
        #expect(AuditRow.when(yesterday, now: now, timeZone: tz) == "17 Aug 18:00 · 1d ago")
    }
}
