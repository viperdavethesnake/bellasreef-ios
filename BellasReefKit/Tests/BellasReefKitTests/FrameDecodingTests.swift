// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

/// Frames captured off a real hub, byte for byte.
///
/// Hand-written fixtures test the fixture author's beliefs about the wire. These
/// came from `ws://bellasreef.local:8000/api/v1/stream` with a DS18B20 on the
/// bus, so they carry the things a hand-written sample forgets: `schema_version`
/// on the payload but not the envelope, a null `calibration_id`, and timestamps
/// with microsecond precision and a `Z` suffix rather than `+00:00`.
///
/// The generated types are `extra`-tolerant on decode but strict on shape, so
/// this is the test that fails if the backend changes a field name — which is
/// the whole point of PRD G3's "no hand-written frame structs" rule.
enum Fixtures {
    static let ready = """
    {"frame_version":1,"received_at":"2026-08-10T06:25:20.454993Z","kind":"ready",\
    "client_id":"71e9d6a0-6b81-4270-92d7-1b00cda0d5a5"}
    """

    static let sensor = """
    {"frame_version":1,"received_at":"2026-08-10T06:25:22.368219Z","kind":"sensor",\
    "subject":"bellasreef.sensor.temp.ds18b20-28-000000bfe244","payload":{\
    "schema_version":2,"message_id":"e9889b54-c16e-4630-9267-b866ecdccf37",\
    "emitted_at":"2026-08-10T06:25:22.367842Z","source":"hardware-io",\
    "sensor_id":"ds18b20-28-000000bfe244","sensor_type":"temp","value":23.812,\
    "unit":"degC","quality":"ok","calibration_id":null}}
    """

    /// The same reading with the probe faulted. `value` is null — the field the
    /// generator silently dropped until the spec emitted 3.1 nullability, so
    /// this case is load-bearing rather than decorative.
    static let faulted = """
    {"frame_version":1,"received_at":"2026-08-10T06:25:22.368219Z","kind":"sensor",\
    "subject":"bellasreef.sensor.temp.ds18b20-28-000000bfe244","payload":{\
    "schema_version":2,"message_id":"e9889b54-c16e-4630-9267-b866ecdccf37",\
    "emitted_at":"2026-08-10T06:25:22.367842Z","source":"hardware-io",\
    "sensor_id":"ds18b20-28-000000bfe244","sensor_type":"temp","value":null,\
    "unit":"degC","quality":"fault","calibration_id":null}}
    """
    /// A breach, captured from the shape the hub publishes.
    static let alert = """
    {"frame_version":1,"received_at":"2026-08-10T07:02:11.104233Z","kind":"alert",\
    "subject":"bellasreef.alert.ds18b20-28-000000bfe244","payload":{\
    "schema_version":2,"message_id":"3f1c1a54-2c1e-4c8a-9f61-5d3b1a9e77aa",\
    "emitted_at":"2026-08-10T07:02:11.103998Z","source":"control-engine",\
    "device_id":"ds18b20-28-000000bfe244","sensor_type":"temp","state":"breach",\
    "bound":"min","value":23.1,"threshold":24.0,"clear_margin":0.5,"unit":"degC"}}
    """
}

@Suite("Frame decoding")
struct FrameDecodingTests {
    private let client = StreamClient(baseURL: URL(string: "http://example.invalid")!)

    @Test("a real ready frame decodes")
    func readyFrame() throws {
        guard case let .ready(frame) = try client.decode(Fixtures.ready) else {
            Issue.record("expected a ready frame")
            return
        }
        // `frame_version` is a const in the schema, so the generator emitted a
        // single-case enum. That is stricter than an Int and deliberately so: a
        // hub that bumps to version 2 fails to decode here rather than being
        // waved through by a comparison nobody remembered to write.
        #expect(frame.frameVersion == ._1)
        #expect(frame.clientId == "71e9d6a0-6b81-4270-92d7-1b00cda0d5a5")
    }

    @Test("a real sensor frame decodes with its value intact")
    func sensorFrame() throws {
        guard case let .sensor(frame) = try client.decode(Fixtures.sensor) else {
            Issue.record("expected a sensor frame")
            return
        }
        #expect(frame.payload.sensorId == "ds18b20-28-000000bfe244")
        #expect(frame.payload.sensorType == "temp")
        #expect(frame.payload.unit == "degC")
        #expect(frame.payload.quality == .ok)
        #expect(frame.payload.value == 23.812)
    }

    @Test("microsecond timestamps parse")
    func fractionalSeconds() throws {
        guard case let .sensor(frame) = try client.decode(Fixtures.sensor) else {
            Issue.record("expected a sensor frame")
            return
        }
        // 2026-08-10T06:25:22.367842Z
        #expect(abs(frame.payload.emittedAt.timeIntervalSince1970 - 1_786_343_122.367842) < 0.001)
    }

    @Test("a faulted reading decodes with a nil value rather than failing")
    func faultedReading() throws {
        guard case let .sensor(frame) = try client.decode(Fixtures.faulted) else {
            Issue.record("expected a sensor frame")
            return
        }
        #expect(frame.payload.value == nil)
        #expect(frame.payload.quality == .fault)
    }

    @Test("a real alert frame decodes")
    func alertFrame() throws {
        guard case let .alert(frame) = try client.decode(Fixtures.alert) else {
            Issue.record("expected an alert frame")
            return
        }
        #expect(frame.payload.deviceId == "ds18b20-28-000000bfe244")
        #expect(frame.payload.state == .breach)
        #expect(frame.payload.bound == .min)
        #expect(frame.payload.value == 23.1)
        #expect(frame.payload.threshold == 24.0)
        #expect(frame.payload.clearMargin == 0.5)
    }

    @Test("an unknown kind is skipped, not fatal")
    func unknownKind() throws {
        // Deliberately different from the spine, where an unknown message is
        // rejected loudly. This is a display stream: refusing to render the
        // temperature because the hub also sent a frame type this build
        // predates is worse than ignoring that frame. Real drift — a renamed
        // field on a kind we *do* know — still throws, which is the property
        // PRD G3 exists to protect, and `undecodableSensorFrame` covers it.
        let future = """
        {"frame_version":1,"received_at":"2026-08-10T06:25:20.454993Z","kind":"alarm"}
        """
        guard case let .unknown(kind) = try client.decode(future) else {
            Issue.record("expected the frame to be skipped")
            return
        }
        #expect(kind == "alarm")
    }

    @Test("a renamed field on a known kind is still a hard error")
    func undecodableSensorFrame() {
        // `payload` present but missing its required `sensor_id`. This is what
        // contract drift actually looks like, and it must not be silently
        // skipped the way an unknown kind is.
        let drifted = """
        {"frame_version":1,"received_at":"2026-08-10T06:25:22.368219Z","kind":"sensor",\
        "subject":"bellasreef.sensor.temp.x","payload":{"schema_version":2,\
        "message_id":"e9889b54-c16e-4630-9267-b866ecdccf37",\
        "emitted_at":"2026-08-10T06:25:22.367842Z","source":"hardware-io",\
        "probe_id":"renamed","sensor_type":"temp","value":23.8,"unit":"degC",\
        "quality":"ok","calibration_id":null}}
        """
        #expect(throws: StreamClient.StreamError.self) {
            _ = try client.decode(drifted)
        }
    }

    @Test("an undecodable frame's payload is a human phrase, not a decoder dump")
    func undecodableFramePayloadIsHumanReadable() {
        // Same fixture as `undecodableSensorFrame`: `payload` present but
        // missing its required `sensor_id`. The Tank status pill and its
        // VoiceOver label render this string directly via `.contractMismatch`
        // (see `TankMonitor.run()`), so it must never carry a `DecodingError`
        // dump.
        let drifted = """
        {"frame_version":1,"received_at":"2026-08-10T06:25:22.368219Z","kind":"sensor",\
        "subject":"bellasreef.sensor.temp.x","payload":{"schema_version":2,\
        "message_id":"e9889b54-c16e-4630-9267-b866ecdccf37",\
        "emitted_at":"2026-08-10T06:25:22.367842Z","source":"hardware-io",\
        "probe_id":"renamed","sensor_type":"temp","value":23.8,"unit":"degC",\
        "quality":"ok","calibration_id":null}}
        """
        do {
            _ = try client.decode(drifted)
            Issue.record("expected the drifted frame to fail to decode")
        } catch StreamClient.StreamError.undecodableFrame(let detail) {
            #expect(detail.contains("sensor"))
            #expect(!detail.contains("DecodingError"))
            #expect(!detail.contains("codingPath"))
            #expect(!detail.contains("CodingKeys"))
        } catch {
            Issue.record("expected .undecodableFrame, got \(error)")
        }
    }

    @Test("a frame with no 'kind' field gets a phrase too, not a decoder dump")
    func undecodableFrameMissingKindIsHumanReadable() {
        let noKind = """
        {"frame_version":1,"received_at":"2026-08-10T06:25:20.454993Z"}
        """
        do {
            _ = try client.decode(noKind)
            Issue.record("expected decode to fail without a 'kind' field")
        } catch StreamClient.StreamError.undecodableFrame(let detail) {
            #expect(!detail.contains("DecodingError"))
            #expect(!detail.contains("codingPath"))
            #expect(!detail.contains("CodingKeys"))
        } catch {
            Issue.record("expected .undecodableFrame, got \(error)")
        }
    }
}
