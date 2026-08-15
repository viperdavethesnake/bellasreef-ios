// Bella's Reef iOS — closed source.

import BellasReefAPI
import Testing

@testable import BellasReefKit

/// UX fix, 2026-08-15 walkthrough: an unadopted device stayed listed as
/// adopted, and a second unadopt hit a stale-row 404 on the hub. The backend
/// keeps detached rows by design and now says so on the wire
/// (`DeviceView.adopted`); `hardwareSections` is the pure split that lets the
/// System screen render two truthful sections instead of one that lies.
private func device(id: String, adopted: Bool) -> Components.Schemas.DeviceView {
    .init(
        adopted: adopted,
        deviceId: id,
        displayName: id,
        driverId: "pca9685",
        enabled: true,
        kind: "actuator"
    )
}

@Suite("Hardware sections")
struct HardwareSectionsTests {
    @Test("split separates adopted from detached")
    func splitOnAdopted() {
        let rows = [device(id: "a", adopted: true), device(id: "b", adopted: false)]
        let split = hardwareSections(rows)
        #expect(split.adopted.map(\.deviceId) == ["a"])
        #expect(split.detached.map(\.deviceId) == ["b"])
    }

    @Test("all adopted leaves detached empty, order preserved")
    func allAdopted() {
        let rows = [device(id: "a", adopted: true), device(id: "b", adopted: true)]
        let split = hardwareSections(rows)
        #expect(split.adopted.map(\.deviceId) == ["a", "b"])
        #expect(split.detached.isEmpty)
    }

    @Test("empty input produces two empty sections")
    func empty() {
        let split = hardwareSections([])
        #expect(split.adopted.isEmpty)
        #expect(split.detached.isEmpty)
    }
}
