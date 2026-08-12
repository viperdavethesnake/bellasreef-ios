// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Security
import Testing

@testable import BellasReefKit

// MARK: - Doubles

/// Answers the generated client without a network.
///
/// This is what the `transport` seam on `HubClient` bought. Before it, every
/// auth path in this package was untestable — the transport was hardcoded to
/// `URLSessionTransport()`, so the twenty tests that existed covered
/// temperature, themes, ages and frame decoding, and nothing that could lock an
/// operator out.
struct StubTransport: ClientTransport {
    /// `(operationID, request, request body) -> (status, response body)`
    let handle: @Sendable (String, HTTPRequest, Data) async throws -> (Int, Data?)

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var payload = Data()
        if let body { payload = try await Data(collecting: body, upTo: 1 << 20) }
        let (status, data) = try await handle(operationID, request, payload)
        var response = HTTPResponse(status: .init(code: status))
        guard let data else { return (response, nil) }
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(data))
    }
}

/// A credential store that lives in memory, and can be told to fail its
/// pre-flight the way a Keychain without entitlements does.
final class MemoryCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private let probeError: (any Error)?

    init(token: String? = nil, probeError: (any Error)? = nil) {
        self.token = token
        self.probeError = probeError
    }

    func probe() throws { if let probeError { throw probeError } }
    func save(_ token: String, hub: String) throws { lock.withLock { self.token = token } }
    func load() throws -> String? { lock.withLock { token } }
    func clear() throws { lock.withLock { token = nil } }
}

/// Which operations reached the wire, in order.
actor CallLog {
    private(set) var operations: [String] = []
    func record(_ operation: String) { operations.append(operation) }
    func count(of operation: String) -> Int { operations.filter { $0 == operation }.count }
    var isEmpty: Bool { operations.isEmpty }
}

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

// MARK: - The 202 body

@Suite("Pairing by code")
struct PairingTests {

    @Test("a 202 hands the screen the code and the expiry, not just a request id")
    func pendingCarriesTheCode() async throws {
        let transport = StubTransport { operation, _, _ in
            #expect(operation == "pair")
            return (202, json("""
            {"request_id":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","pairing_code":"482913",\
            "poll_after_s":5,"expires_in_s":300}
            """))
        }
        let client = HubClient(hub: anyHub, tokens: MemoryCredentials(), transport: transport)

        guard case let .pending(pending) = try await client.pair(clientName: "iPad 9F21") else {
            Issue.record("a 202 did not produce a pending outcome")
            return
        }
        #expect(pending.pairingCode == "482913")
        #expect(pending.pollAfter == 5)
        // The screen used to say "five minutes" in a hardcoded label while this
        // number arrived and was dropped on the floor.
        #expect(pending.expiresIn == 300)
    }

    @Test("a 403 on pair means nobody can approve, not a generic failure")
    func forbiddenMeansRecovery() async throws {
        let transport = StubTransport { _, _, _ in (403, nil) }
        let client = HubClient(hub: anyHub, tokens: MemoryCredentials(), transport: transport)

        guard case .needsRecoveryCLI = try await client.pair(clientName: "iPad") else {
            Issue.record("403 should send the operator to `bellasreef pair`")
            return
        }
    }

    @Test("losing the recovery window is named, not swallowed")
    func recoveryWindowRace() async {
        let transport = StubTransport { _, _, _ in (409, nil) }
        let client = HubClient(hub: anyHub, tokens: MemoryCredentials(), transport: transport)

        await #expect(throws: HubClient.ClientError.self) {
            _ = try await client.pair(clientName: "iPad")
        }
    }

    // MARK: The pre-flight

    @Test("a Keychain that cannot hold a credential stops pairing before the hub spends anything")
    func keychainPreflight() async {
        let log = CallLog()
        let transport = StubTransport { operation, _, _ in
            await log.record(operation)
            return (200, json(#"{"refresh_token":"rt","client_id":"c"}"#))
        }
        let client = HubClient(
            hub: anyHub,
            tokens: MemoryCredentials(probeError: TokenStore.StoreError.keychain(errSecMissingEntitlement)),
            transport: transport
        )

        await #expect(throws: HubClient.ClientError.self) {
            _ = try await client.pair(clientName: "iPad")
        }
        // The assertion that matters. A store failure *after* POST /pair means
        // the hub has issued the only copy of a credential and spent its TOFU
        // or recovery window doing it, and the operator's way back is SSH.
        #expect(await log.isEmpty, "the request reached the hub despite an unusable Keychain")
    }

    // MARK: Poll

    @Test(
        "every documented poll status becomes a distinct outcome",
        arguments: [
            (202, HubClient.PollOutcome.stillPending),
            (403, .denied),
            (404, .unknown),
            (410, .gone),
        ]
    )
    func pollStatuses(status: Int, expected: HubClient.PollOutcome) async throws {
        let transport = StubTransport { _, _, _ in (status, nil) }
        let client = HubClient(hub: anyHub, tokens: MemoryCredentials(), transport: transport)

        let outcome = try await client.poll(requestId: "3f2504e0-4f89-41d3-9a0c-0305e82c3301")
        #expect(outcome == expected)
    }

    @Test("a 200 on poll carries the credential")
    func pollGrants() async throws {
        let transport = StubTransport { _, _, _ in
            (200, json(#"{"refresh_token":"rt-collected","client_id":"1e1"}"#))
        }
        let client = HubClient(hub: anyHub, tokens: MemoryCredentials(), transport: transport)

        #expect(
            try await client.poll(requestId: "3f2504e0-4f89-41d3-9a0c-0305e82c3301")
                == .granted(refreshToken: "rt-collected", clientId: "1e1")
        )
    }

    // MARK: Claim

    @Test(
        "claim keeps 404, 409 and 422 apart, because they send the operator to different places",
        arguments: [
            (404, HubClient.ClaimOutcome.noSuchCode),
            (409, .notPending),
            (422, .malformed),
        ]
    )
    func claimStatuses(status: Int, expected: HubClient.ClaimOutcome) async throws {
        let transport = StubTransport { operation, _, _ in
            // Claim is authenticated, so the middleware mints first.
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            // 422 carries FastAPI's validation envelope; the others carry
            // nothing. Both shapes have to decode.
            return status == 422 ? (status, json(#"{"detail":[]}"#)) : (status, nil)
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "rt"), transport: transport
        )

        #expect(try await client.claim(code: "482913") == expected)
    }

    // MARK: 401 handling

    @Test("a 401 on an authenticated call drops the cached access token instead of resending it")
    func staleAccessTokenIsDropped() async throws {
        let log = CallLog()
        let transport = StubTransport { operation, _, _ in
            await log.record(operation)
            switch operation {
            case "mintToken":
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            case "listClients":
                // First call is rejected; second would succeed with a fresh
                // token.
                return await log.count(of: "listClients") == 1 ? (401, nil) : (200, json("[]"))
            default:
                return (500, nil)
            }
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "rt"), transport: transport
        )

        await #expect(throws: HubClient.ClientError.self) { _ = try await client.clients() }
        _ = try await client.clients()

        // Without invalidation the cached token is good for another fourteen
        // minutes by the clock, so the second call would reuse the dead one and
        // mint exactly once for the whole run.
        #expect(await log.count(of: "mintToken") == 2)
    }

    @Test("clients() returns the rows a revoke screen needs, live ones only")
    func clientsAreRowsNotACount() async throws {
        let transport = StubTransport { operation, _, _ in
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            return (200, json("""
            [{"id":"a","name":"iPhone 3F9C","created_at":"2026-08-01T00:00:00Z",\
            "last_seen_at":"2026-08-12T00:00:00Z","revoked_at":null},\
            {"id":"b","name":"iPad 9F21","created_at":"2026-08-02T00:00:00Z",\
            "last_seen_at":null,"revoked_at":null},\
            {"id":"c","name":"old phone","created_at":"2026-07-01T00:00:00Z",\
            "last_seen_at":"2026-07-02T00:00:00Z","revoked_at":"2026-07-03T00:00:00Z"}]
            """))
        }
        let client = HubClient(
            hub: anyHub, tokens: MemoryCredentials(token: "rt"), transport: transport
        )

        let rows = try await client.clients()
        #expect(rows.map(\.name) == ["iPhone 3F9C", "iPad 9F21"])
    }
}

// MARK: - The journey

/// A hub that holds exactly one pairing request, and the rules around it.
///
/// Small on purpose: the only behaviour worth faking is the part the two
/// participants disagree about — who knows the code, who knows the request id,
/// and how many times a credential can be collected.
actor FakeHub {
    static let code = "482913"
    static let requestId = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    private var approved = false
    private var collected = false

    func pair() -> (Int, Data?) {
        (202, json("""
        {"request_id":"\(Self.requestId)","pairing_code":"\(Self.code)",\
        "poll_after_s":1,"expires_in_s":300}
        """))
    }

    func claim(_ body: Data) -> (Int, Data?) {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let offered = parsed["code"] as? String
        else { return (422, json(#"{"detail":[]}"#)) }

        guard offered == Self.code else { return (404, nil) }
        guard !approved else { return (409, nil) }
        approved = true
        return (200, json(#"{"request_id":"\#(Self.requestId)"}"#))
    }

    func poll(path: String) -> (Int, Data?) {
        guard path.hasSuffix(Self.requestId) else { return (404, nil) }
        guard approved else { return (202, nil) }
        // One credential per approval. A second poll is a 410, not a second
        // token.
        guard !collected else { return (410, nil) }
        collected = true
        return (200, json(#"{"refresh_token":"rt-new-device","client_id":"new-client"}"#))
    }

    func mint() -> (Int, Data?) { (200, json(#"{"access_token":"jwt","expires_in":900}"#)) }
}

enum ApproverMisuse: Error { case notASixDigitCode }

/// The approver, restricted to what a person could actually obtain.
///
/// It takes six digits and refuses anything else. This is the whole lesson of
/// the review as a function signature: the backend's approval test passed for
/// months because it kept the `request_id` from the pairing call and handed it
/// straight to the approver, so a journey no operator could complete stayed
/// green. Hand this a request id and it fails on the way in.
func approve(code: String, from client: HubClient) async throws -> HubClient.ClaimOutcome {
    guard code.count == 6, code.allSatisfy(\.isNumber) else { throw ApproverMisuse.notASixDigitCode }
    return try await client.claim(code: code)
}

@Suite("Second-device journey")
struct SecondDeviceJourneyTests {

    private func client(for hub: FakeHub, refreshToken: String? = nil) -> HubClient {
        HubClient(
            hub: anyHub,
            tokens: MemoryCredentials(token: refreshToken),
            transport: StubTransport { operation, request, body in
                switch operation {
                case "pair": return await hub.pair()
                case "claimPairing": return await hub.claim(body)
                case "pollPairing": return await hub.poll(path: request.path ?? "")
                case "mintToken": return await hub.mint()
                default: return (500, nil)
                }
            }
        )
    }

    @Test("a second device pairs by code, with nothing shared between the two participants")
    func journey() async throws {
        let hub = FakeHub()
        let newDevice = client(for: hub)
        let approver = client(for: hub, refreshToken: "rt-approver")

        // The new device asks, and gets a code it can show on its screen.
        guard case let .pending(pending) = try await newDevice.pair(clientName: "iPad 9F21") else {
            Issue.record("the hub did not put this device in the queue")
            return
        }
        #expect(try await newDevice.poll(requestId: pending.requestId) == .stillPending)

        // The approver gets six digits, which is everything a person reading a
        // screen could carry across. Nothing else crosses this line.
        guard case .approved = try await approve(code: pending.pairingCode, from: approver) else {
            Issue.record("the code did not resolve to a pending request")
            return
        }

        // And only now does the waiting device collect — once.
        #expect(
            try await newDevice.poll(requestId: pending.requestId)
                == .granted(refreshToken: "rt-new-device", clientId: "new-client")
        )
        #expect(try await newDevice.poll(requestId: pending.requestId) == .gone)
    }

    @Test("the approver refuses anything that is not six digits")
    func approverRefusesARequestId() async {
        let hub = FakeHub()
        let approver = client(for: hub, refreshToken: "rt-approver")

        await #expect(throws: ApproverMisuse.self) {
            _ = try await approve(code: FakeHub.requestId, from: approver)
        }
    }

    @Test("a wrong code is a 404, and does not approve the waiting request")
    func wrongCode() async throws {
        let hub = FakeHub()
        let newDevice = client(for: hub)
        let approver = client(for: hub, refreshToken: "rt-approver")

        guard case let .pending(pending) = try await newDevice.pair(clientName: "iPad") else {
            Issue.record("no pending request")
            return
        }
        #expect(try await approve(code: "000000", from: approver) == .noSuchCode)
        #expect(try await newDevice.poll(requestId: pending.requestId) == .stillPending)
    }
}

// MARK: - Naming

@Suite("Device naming")
struct DeviceNameTests {

    @Test("two devices never suggest the same name")
    func distinct() {
        let first = DeviceName.suggested(model: "iPhone", vendorId: UUID(uuidString: "3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
        let second = DeviceName.suggested(model: "iPhone", vendorId: UUID(uuidString: "a1b2c3d4-4f89-41d3-9a0c-0305e82c3301"))
        // Both are "iPhone" to UIKit without the entitlement, which is how a
        // clients list becomes a column of identical rows with a Revoke button
        // beside each.
        #expect(first != second)
        #expect(first == "iPhone 3F25")
    }

    @Test("no vendor id gives a plain name rather than one that changes every launch")
    func noVendorId() {
        #expect(DeviceName.suggested(model: "iPad", vendorId: nil) == "iPad")
    }

    @Test("the hub's own limits decide what the button will send")
    func usable() {
        #expect(!DeviceName.isUsable("   "))
        #expect(!DeviceName.isUsable(String(repeating: "a", count: 129)))
        #expect(DeviceName.isUsable("Sump iPad"))
    }
}
