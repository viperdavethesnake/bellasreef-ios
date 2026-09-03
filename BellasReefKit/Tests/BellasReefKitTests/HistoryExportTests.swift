// Bella's Reef iOS — closed source.

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import UniformTypeIdentifiers

@testable import BellasReefKit

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

/// An instant, stated in a zone that is not UTC.
///
/// `ISO8601DateFormatter` rather than a `DateComponents` build: the offset is
/// the point of several of these tests, and writing it into the string is the
/// only form where the expected UTC answer is readable beside it.
private func instant(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: text) else {
        fatalError("bad fixture date: \(text)")
    }
    return date
}

// MARK: - The filename the backend would have sent

@Suite("Export filename")
struct ExportFilenameTests {

    /// Mirrors `history_export`'s own stem
    /// (`services/api/bellasreef_api/app.py`): `bellasreef-<device_id>` then
    /// each bound as `%Y%m%dT%H%MZ`, then the format's extension. Written
    /// against the backend source rather than against a captured header, so a
    /// drift on either side shows up here.
    @Test("built stem matches the backend's, character for character")
    func stemMatchesBackend() {
        let name = ExportFilename.build(
            deviceId: "pca9685-0",
            start: instant("2026-09-03T00:00:00Z"),
            end: instant("2026-09-03T06:00:00Z"),
            format: .csv
        )
        #expect(name == "bellasreef-pca9685-0-20260903T0000Z-20260903T0600Z.csv")
    }

    @Test("json exports carry the json extension")
    func jsonExtension() {
        let name = ExportFilename.build(
            deviceId: "28-000000bfe244",
            start: instant("2026-09-03T00:00:00Z"),
            end: instant("2026-09-03T06:00:00Z"),
            format: .json
        )
        #expect(name == "bellasreef-28-000000bfe244-20260903T0000Z-20260903T0600Z.json")
    }

    /// The window the app sends is `now - duration ... now`, which on this
    /// machine is Pacific. The backend stamps `start.astimezone(UTC)`, so a
    /// formatter left on the device's zone would produce a name that
    /// disagrees with the hub's own header — and, at these two instants,
    /// names the wrong day.
    @Test("stamps in UTC, not in the device's zone")
    func stampsInUTC() {
        let name = ExportFilename.build(
            deviceId: "pi-pwm-0",
            start: instant("2026-09-03T23:30:00-07:00"),
            end: instant("2026-09-04T05:30:00-07:00"),
            format: .csv
        )
        #expect(name == "bellasreef-pi-pwm-0-20260904T0630Z-20260904T1230Z.csv")
    }
}

// MARK: - The filename the hub actually sent

@Suite("Content-Disposition")
struct ContentDispositionTests {

    /// The shape the hub sends today: quoted, one parameter.
    @Test("a quoted filename comes back unquoted")
    func quoted() {
        let name = ContentDisposition.filename(
            from: #"attachment; filename="bellasreef-pca9685-0-20260903T0000Z-20260903T0600Z.csv""#
        )
        #expect(name == "bellasreef-pca9685-0-20260903T0000Z-20260903T0600Z.csv")
    }

    /// Legal per RFC 6266 and what several servers send; the hub does not,
    /// which is exactly why it is worth a test rather than an assumption.
    @Test("an unquoted filename is accepted too")
    func unquoted() {
        #expect(ContentDisposition.filename(from: "attachment; filename=export.json")
            == "export.json")
    }

    @Test("no header at all is nil, not an empty name")
    func missing() {
        #expect(ContentDisposition.filename(from: nil) == nil)
    }

    /// A bare `attachment` is a legal header that names nothing. Returning ""
    /// here would put a file called "" in the temporary directory.
    @Test("a header with no filename parameter is nil")
    func noFilenameParameter() {
        #expect(ContentDisposition.filename(from: "attachment") == nil)
        #expect(ContentDisposition.filename(from: "inline; size=1024") == nil)
    }

    @Test("parameter name matching ignores case and surrounding space")
    func caseAndSpace() {
        #expect(ContentDisposition.filename(from: #"attachment ;  FileName = "a.csv" "#)
            == "a.csv")
    }

    /// RFC 5987's encoded form is deliberately not decoded — the hub never
    /// sends it, and a half-implemented percent/charset decoder would be a
    /// worse answer than falling back to the name we can build exactly.
    @Test("filename* alone is not mistaken for filename")
    func encodedFormIgnored() {
        #expect(ContentDisposition.filename(from: "attachment; filename*=UTF-8''a%20b.csv") == nil)
    }

    /// The value is about to become a path in the temporary directory. It
    /// arrives from the network, so it is reduced to a last path component
    /// before it can name anywhere else — even though this hub's device ids
    /// are `[a-z0-9_-]` and could not produce one.
    @Test("a path in the value is reduced to its last component")
    func pathsAreStripped() {
        #expect(ContentDisposition.filename(from: #"attachment; filename="../../etc/passwd""#)
            == "passwd")
        #expect(ContentDisposition.filename(from: #"attachment; filename="/tmp/a.csv""#) == "a.csv")
    }

    @Test("an empty or dot-only value is nil")
    func emptyValue() {
        #expect(ContentDisposition.filename(from: #"attachment; filename="""#) == nil)
        #expect(ContentDisposition.filename(from: "attachment; filename=..") == nil)
    }
}

// MARK: - The wrapper

/// A transport that can answer with something other than JSON.
///
/// The shared `StubTransport` pins `Content-Type: application/json`, which is
/// the one thing this operation must be exercised without: the generated
/// deserializer picks `.csv` or `.json` off the response's content type, so a
/// JSON-only stub can never reach the CSV case at all.
private struct ExportTransport: ClientTransport {
    struct Reply {
        var status: Int
        var contentType: String?
        var disposition: String?
        var body: Data?
    }

    let handle: @Sendable (String, HTTPRequest) async throws -> Reply

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if operationID == "mintToken" {
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            return (
                response,
                HTTPBody(Data(#"{"access_token":"jwt","expires_in":900}"#.utf8))
            )
        }
        let reply = try await handle(operationID, request)
        var response = HTTPResponse(status: .init(code: reply.status))
        if let contentType = reply.contentType { response.headerFields[.contentType] = contentType }
        if let disposition = reply.disposition {
            response.headerFields[.contentDisposition] = disposition
        }
        guard let data = reply.body else { return (response, nil) }
        return (response, HTTPBody(data))
    }
}

private let csvBody = """
    at,device_id,metric,value,quality
    2026-09-03T00:00:00Z,pca9685-0,bellasreef_actuator_level,0.15,
    2026-09-03T00:00:05Z,pca9685-0,bellasreef_actuator_level,0.16,

    """

private let window = (start: instant("2026-09-03T00:00:00Z"), end: instant("2026-09-03T06:00:00Z"))

@Suite("History export wrapper")
struct HistoryExportClientTests {

    private func client(
        _ handle: @escaping @Sendable (String, HTTPRequest) async throws -> ExportTransport.Reply
    ) -> HubClient {
        HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "refresh"),
            transport: ExportTransport(handle: handle)
        )
    }

    /// The whole point of the feature: bytes out, named the way the hub named
    /// them, typed so the share sheet offers the right destinations.
    @Test("a CSV 200 comes back as bytes, named by the hub's own header")
    func csvUsesTheHubsName() async throws {
        let client = client { operation, request in
            #expect(operation == "historyExport")
            let query = request.path ?? ""
            // The query is asserted here rather than trusted: `format` is
            // what decides which of the two content types comes back, and
            // sending the default instead of the choice would silently
            // export CSV for a JSON request.
            #expect(query.contains("device_id=pca9685-0"))
            #expect(query.contains("format=csv"))
            return .init(
                status: 200,
                contentType: "text/csv; charset=utf-8",
                // Deliberately NOT the name `ExportFilename.build` would
                // produce for this window. The real hub sends exactly that
                // name, which means a test using it passes whether the
                // header was read or silently ignored — the first version of
                // this test did, and proved nothing about the middleware.
                disposition: #"attachment; filename="named-by-the-hub.csv""#,
                body: Data(csvBody.utf8)
            )
        }

        let file = try await client.exportHistory(
            deviceId: "pca9685-0", from: window.start, to: window.end, format: .csv
        )
        #expect(String(decoding: file.data, as: UTF8.self) == csvBody)
        #expect(file.suggestedFilename == "named-by-the-hub.csv")
        #expect(file.utType == .commaSeparatedText)
    }

    /// The header is documented in the handler but not declared in the spec,
    /// so a hub that stops sending it breaks nothing: the same name is built
    /// from the window that was requested.
    @Test("a CSV 200 with no disposition header falls back to the built name")
    func csvWithoutHeader() async throws {
        let client = client { _, _ in
            .init(
                status: 200, contentType: "text/csv; charset=utf-8", disposition: nil,
                body: Data(csvBody.utf8)
            )
        }

        let file = try await client.exportHistory(
            deviceId: "pca9685-0", from: window.start, to: window.end, format: .csv
        )
        #expect(file.suggestedFilename == "bellasreef-pca9685-0-20260903T0000Z-20260903T0600Z.csv")
    }

    /// The JSON leg goes through the generated model — the generator hands
    /// back a decoded `HistoryExport`, not bytes — so this asserts the round
    /// trip preserves the samples rather than asserting on a byte string.
    @Test("a JSON 200 round-trips every sample through the generated model")
    func jsonRoundTrips() async throws {
        let client = client { _, request in
            #expect((request.path ?? "").contains("format=json"))
            return .init(
                status: 200, contentType: "application/json",
                disposition: #"attachment; filename="bellasreef-pca9685-0-20260903T0000Z-20260903T0600Z.json""#,
                body: Data(#"""
                    {"device_id":"pca9685-0","metric":"bellasreef_actuator_level",
                     "start":"2026-09-03T00:00:00Z","end":"2026-09-03T06:00:00Z",
                     "samples":[{"at":"2026-09-03T00:00:00Z","value":0.15,"quality":null},
                                {"at":"2026-09-03T00:00:05Z","value":0.16,"quality":"good"}]}
                    """#.utf8)
            )
        }

        let file = try await client.exportHistory(
            deviceId: "pca9685-0", from: window.start, to: window.end, format: .json
        )
        #expect(file.utType == .json)
        #expect(file.suggestedFilename.hasSuffix(".json"))

        let decoded = try JSONSerialization.jsonObject(with: file.data) as? [String: Any]
        #expect(decoded?["device_id"] as? String == "pca9685-0")
        #expect(decoded?["metric"] as? String == "bellasreef_actuator_level")
        let samples = decoded?["samples"] as? [[String: Any]]
        #expect(samples?.count == 2)
        #expect(samples?[0]["value"] as? Double == 0.15)
        #expect(samples?[1]["quality"] as? String == "good")
    }

    /// 404 is a device the registry does not have, which is a different
    /// problem from an empty window and must not read as "nothing recorded".
    @Test("a 404 says the device is unknown")
    func unknownDevice() async throws {
        let client = client { _, _ in .init(status: 404, contentType: nil, disposition: nil, body: nil) }

        await #expect(throws: HubClient.ClientError.self) {
            _ = try await client.exportHistory(
                deviceId: "ghost", from: window.start, to: window.end, format: .csv
            )
        }
    }

    /// 422 is the 31-day cap and the naive-datetime guard. The app's widest
    /// range is 7D so it should be unreachable, which is why it gets a
    /// sentence rather than a crash.
    @Test("a 422 is a refused window, not an unexpected status")
    func refusedWindow() async throws {
        let client = client { _, _ in .init(status: 422, contentType: nil, disposition: nil, body: nil) }

        do {
            _ = try await client.exportHistory(
                deviceId: "pca9685-0", from: window.start, to: window.end, format: .csv
            )
            Issue.record("a 422 should not succeed")
        } catch let error as HubClient.ClientError {
            guard case .rejected = error else {
                Issue.record("422 should be a rejection, got \(error)")
                return
            }
        }
    }

    @Test("a 503 names the missing telemetry store")
    func noStore() async throws {
        let client = client { _, _ in .init(status: 503, contentType: nil, disposition: nil, body: nil) }

        do {
            _ = try await client.exportHistory(
                deviceId: "pca9685-0", from: window.start, to: window.end, format: .csv
            )
            Issue.record("a 503 should not succeed")
        } catch let error as HubClient.ClientError {
            #expect(error.description.contains("telemetry store"))
        }
    }
}
