// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

/// UX-3: the Equipment section renders from the device list, not only from
/// stream frames. `equipmentRows` is the merge — every adopted actuator
/// appears exactly once, whether or not a state frame has arrived for it yet,
/// and a frame with no adopted device behind it still shows (today's
/// behaviour must not regress).
private enum EquipmentFixtures {
    static func device(
        id: String, name: String = "Fixture", actuatorClass: String? = "dimmer",
        adopted: Bool = true
    ) -> Components.Schemas.DeviceView {
        .init(
            actuatorClass: actuatorClass,
            adopted: adopted,
            deviceId: id,
            displayName: name,
            driverId: "pca9685",
            enabled: true,
            kind: "actuator"
        )
    }

    static func frame(id: String) -> Components.Schemas.StateFrame {
        .init(
            payload: .init(
                actuatorId: id,
                emittedAt: Date(timeIntervalSince1970: 1_786_343_122),
                level: .binary(.init(on: true)),
                messageId: "e9889b54-c16e-4630-9267-b866ecdccf37",
                reason: .commanded,
                since: Date(timeIntervalSince1970: 1_786_343_122),
                source: "hardware-io"
            ),
            receivedAt: Date(timeIntervalSince1970: 1_786_343_122),
            subject: "bellasreef.state.\(id)"
        )
    }
}

@Suite("Equipment rows")
struct EquipmentRowsTests {
    @Test("nothing adopted and no frames is empty")
    func nothingAtAll() {
        let sections = equipmentRows(devices: [], frames: [:], roles: [:])
        #expect(sections.isEmpty)
    }

    @Test("an adopted actuator with no frame yet renders as adopted-silent")
    func adoptedNoFrame() {
        let device = EquipmentFixtures.device(id: "light-1", name: "Display light")
        let sections = equipmentRows(devices: [device], frames: [:], roles: ["light-1": "light"])

        #expect(sections.count == 1)
        #expect(sections[0].role == "light")
        #expect(sections[0].rows == [.adoptedSilent(id: "light-1", name: "Display light")])
    }

    @Test("an adopted actuator with a frame renders as reporting, once")
    func adoptedWithFrame() {
        let device = EquipmentFixtures.device(id: "light-1", name: "Display light")
        let frame = EquipmentFixtures.frame(id: "light-1")
        let sections = equipmentRows(
            devices: [device], frames: ["light-1": frame], roles: ["light-1": "light"]
        )

        #expect(sections.count == 1)
        #expect(sections[0].rows == [.reporting(id: "light-1", name: "Display light", frame: frame)])
    }

    /// A device does not visibly rename itself the moment its first frame
    /// arrives: `.reporting` carries the same display name `.adoptedSilent`
    /// would have shown, resolved from the registry rather than the wire.
    @Test("an adopted device with a frame renders under its display name")
    func adoptedWithFrameCarriesDisplayName() {
        let device = EquipmentFixtures.device(id: "light-1", name: "Display light")
        let frame = EquipmentFixtures.frame(id: "light-1")
        let sections = equipmentRows(
            devices: [device], frames: ["light-1": frame], roles: ["light-1": "light"]
        )

        guard case let .reporting(_, name, _) = sections[0].rows[0] else {
            Issue.record("expected a reporting row")
            return
        }
        #expect(name == "Display light")
    }

    /// CRITICAL-1: unbind is not a delete — a detached actuator still carries
    /// its `actuatorClass`, so `actuatorClass != nil` alone would keep
    /// showing it as live equipment on the tab that commands it. It belongs
    /// only in `SystemView`'s "Detached" list, not here.
    @Test("a detached actuator (adopted: false) produces no equipment row")
    func detachedActuatorProducesNoRow() {
        let device = EquipmentFixtures.device(id: "light-1", name: "Display light", adopted: false)
        let sections = equipmentRows(devices: [device], frames: [:], roles: ["light-1": "light"])

        #expect(sections.isEmpty)
    }

    @Test("a frame with no adopted device behind it still appears")
    func orphanFrame() {
        let frame = EquipmentFixtures.frame(id: "mystery-1")
        let sections = equipmentRows(
            devices: [], frames: ["mystery-1": frame], roles: ["mystery-1": "pump"]
        )

        #expect(sections.count == 1)
        #expect(sections[0].role == "pump")
        #expect(sections[0].rows == [.reporting(id: "mystery-1", name: "mystery-1", frame: frame)])
    }

    /// No adopted device means no registry name to resolve — the orphan-frame
    /// fallback stays the raw id, same as before this fix.
    @Test("an orphan frame with no adopted device renders under its id")
    func orphanFrameFallsBackToId() {
        let frame = EquipmentFixtures.frame(id: "mystery-1")
        let sections = equipmentRows(
            devices: [], frames: ["mystery-1": frame], roles: ["mystery-1": "pump"]
        )

        guard case let .reporting(_, name, _) = sections[0].rows[0] else {
            Issue.record("expected a reporting row")
            return
        }
        #expect(name == "mystery-1")
    }
}
