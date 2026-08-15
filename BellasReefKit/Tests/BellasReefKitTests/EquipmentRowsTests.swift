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
        id: String, name: String = "Fixture", actuatorClass: String? = "dimmer"
    ) -> Components.Schemas.DeviceView {
        .init(
            actuatorClass: actuatorClass,
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
        #expect(sections[0].rows == [.reporting(id: "light-1", frame: frame)])
    }

    @Test("a frame with no adopted device behind it still appears")
    func orphanFrame() {
        let frame = EquipmentFixtures.frame(id: "mystery-1")
        let sections = equipmentRows(
            devices: [], frames: ["mystery-1": frame], roles: ["mystery-1": "pump"]
        )

        #expect(sections.count == 1)
        #expect(sections[0].role == "pump")
        #expect(sections[0].rows == [.reporting(id: "mystery-1", frame: frame)])
    }
}
