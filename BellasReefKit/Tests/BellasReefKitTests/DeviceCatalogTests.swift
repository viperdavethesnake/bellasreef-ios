// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import BellasReefKit

/// Finding, 2026-10-02 (coco, nothing adopted): `refresh()` decided whether to
/// show `.loading` from `sensors.isEmpty`, which on an empty registry is true
/// forever — every refresh of a confirmed-empty hub went back to "Loading
/// lights…" and an unknown sensor count. And a refresh cancelled by its own
/// `.task` was stored as `.failed`, the same mistake `HistoryModelTests` pins
/// for history. Together they fed the MainTabs strip loop (iOS #34).
private let catalogHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

/// Records what the catalog's state was at the moment each `listSensors`
/// request went out — i.e. what a view would render mid-refresh.
private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [DeviceCatalog.Load] = []
    func append(_ state: DeviceCatalog.Load) { lock.withLock { states.append(state) } }
    var all: [DeviceCatalog.Load] { lock.withLock { states } }
}

@MainActor
@Suite("DeviceCatalog refresh")
struct DeviceCatalogTests {

    @Test("a confirmed-empty registry stays .loaded while it refreshes")
    func emptyRegistryDoesNotReenterLoading() async {
        let seen = StateLog()
        var catalog: DeviceCatalog?
        let transport = StubTransport { operation, _, _ in
            switch operation {
            case "mintToken":
                return (200, Data(#"{"access_token":"jwt","expires_in":900}"#.utf8))
            case "listSensors":
                if let state = await MainActor.run(body: { catalog?.state }) { seen.append(state) }
                return (200, Data("[]".utf8))
            default:
                return (200, Data("[]".utf8))
            }
        }
        let client = HubClient(hub: catalogHub, tokens: MemoryCredentials(token: "rt"), transport: transport)
        catalog = DeviceCatalog(client: client)

        await catalog?.refresh()
        #expect(catalog?.state == .loaded)
        await catalog?.refresh()

        #expect(seen.all == [.loading, .loaded])
        #expect(catalog?.state == .loaded)
    }

    @Test("a cancelled refresh leaves the state it found")
    func cancelledRefreshIsNotAFailure() async {
        let cancelNext = StateLog()  // non-empty once the first load is done
        let transport = StubTransport { operation, _, _ in
            switch operation {
            case "mintToken":
                return (200, Data(#"{"access_token":"jwt","expires_in":900}"#.utf8))
            case "listDevices" where !cancelNext.all.isEmpty:
                throw CancellationError()
            default:
                return (200, Data("[]".utf8))
            }
        }
        let client = HubClient(hub: catalogHub, tokens: MemoryCredentials(token: "rt"), transport: transport)
        let catalog = DeviceCatalog(client: client)

        await catalog.refresh()
        #expect(catalog.state == .loaded)
        cancelNext.append(.loaded)
        await catalog.refresh()

        #expect(catalog.state == .loaded)
    }
}
