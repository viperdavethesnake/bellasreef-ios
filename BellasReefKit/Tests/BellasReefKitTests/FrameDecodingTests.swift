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

    @Test("an unknown kind is surfaced, not swallowed")
    func unknownKind() {
        let future = """
        {"frame_version":1,"received_at":"2026-08-10T06:25:20.454993Z","kind":"alarm"}
        """
        #expect(throws: StreamClient.StreamError.self) {
            _ = try client.decode(future)
        }
    }
}
