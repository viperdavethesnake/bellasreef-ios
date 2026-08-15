// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Testing

@testable import BellasReefKit

/// Feature 2 (lighting manual control): `lightingCards` is the pure merge of
/// the device registry, the stream frame and any active override into what
/// the Lighting tab renders. Mirrors `EquipmentRowsTests`' fixture style —
/// same registry/frame shapes, a lighting-specific filter (`role == "light"`
/// and adopted) and an added active-hold dimension the equipment rows don't
/// carry.
private enum LightingFixtures {
    static func device(
        id: String, name: String = "Fixture", role: String? = "light",
        adopted: Bool = true, maxRuntimeS: Double? = 3600
    ) -> Components.Schemas.DeviceView {
        .init(
            actuatorClass: "dimmer",
            adopted: adopted,
            deviceId: id,
            displayName: name,
            driverId: "pca9685",
            enabled: true,
            kind: "actuator",
            maxRuntimeS: maxRuntimeS,
            role: role
        )
    }

    static func sensor(id: String, name: String = "Probe") -> Components.Schemas.DeviceView {
        .init(
            adopted: true,
            deviceId: id,
            displayName: name,
            driverId: "ds18b20",
            enabled: true,
            kind: "sensor",
            sensorType: "temperature"
        )
    }

    static func frame(
        id: String, duty: Double = 0.42, override: Components.Schemas.OverrideContext? = nil
    ) -> Components.Schemas.StateFrame {
        .init(
            override: override,
            payload: .init(
                actuatorId: id,
                emittedAt: Date(timeIntervalSince1970: 1_786_343_122),
                level: .pwm(.init(duty: duty)),
                messageId: "e9889b54-c16e-4630-9267-b866ecdccf37",
                reason: .commanded,
                since: Date(timeIntervalSince1970: 1_786_343_122),
                source: "hardware-io"
            ),
            receivedAt: Date(timeIntervalSince1970: 1_786_343_122),
            subject: "bellasreef.state.\(id)"
        )
    }

    static func override(
        id: String = "8f14e45f-ceea-467e-9575-6e3c8e9caeb2", duty: Double = 0.6,
        expiresInS: Double = 1200
    ) -> Components.Schemas.OverrideContext {
        .init(
            duty: duty,
            expiresAt: Date(timeIntervalSince1970: 1_786_343_122 + 1200),
            expiresInS: expiresInS,
            id: id
        )
    }
}

@Suite("Lighting cards")
struct LightingCardsTests {

    @Test("an adopted light with a frame carries the reported duty")
    func adoptedWithFrame() {
        let device = LightingFixtures.device(id: "light-1", name: "Display light")
        let frame = LightingFixtures.frame(id: "light-1", duty: 0.42)
        let cards = lightingCards(devices: [device], frames: ["light-1": frame])

        #expect(cards.count == 1)
        #expect(cards[0].id == "light-1")
        #expect(cards[0].name == "Display light")
        #expect(cards[0].reportedDuty == 0.42)
        #expect(cards[0].hold == nil)
        #expect(cards[0].maxRuntimeS == 3600)
    }

    @Test("an adopted light with no frame yet has no reported duty — 'no state yet', not zero")
    func adoptedNoFrame() {
        let device = LightingFixtures.device(id: "light-1", name: "Display light")
        let cards = lightingCards(devices: [device], frames: [:])

        #expect(cards.count == 1)
        #expect(cards[0].reportedDuty == nil)
        #expect(cards[0].hold == nil)
    }

    @Test("a detached light (adopted: false) produces no card")
    func detachedLight() {
        let device = LightingFixtures.device(id: "light-1", adopted: false)
        let frame = LightingFixtures.frame(id: "light-1")
        let cards = lightingCards(devices: [device], frames: ["light-1": frame])

        #expect(cards.isEmpty)
    }

    @Test("a sensor produces no card")
    func sensorProducesNoCard() {
        let sensor = LightingFixtures.sensor(id: "probe-1")
        let cards = lightingCards(devices: [sensor], frames: [:])

        #expect(cards.isEmpty)
    }

    @Test("a non-light actuator (e.g. a heater) produces no card")
    func nonLightActuatorProducesNoCard() {
        let device = LightingFixtures.device(id: "heater-1", role: "heater")
        let cards = lightingCards(devices: [device], frames: [:])

        #expect(cards.isEmpty)
    }

    @Test("a frame carrying an override shows the active hold — duty and remaining")
    func frameWithOverrideShowsHold() {
        let device = LightingFixtures.device(id: "light-1")
        let override = LightingFixtures.override(duty: 0.6, expiresInS: 1200)
        let frame = LightingFixtures.frame(id: "light-1", duty: 0.6, override: override)
        let cards = lightingCards(devices: [device], frames: ["light-1": frame])

        #expect(cards.count == 1)
        #expect(cards[0].hold == LightingCard.ActiveHold(
            id: "8f14e45f-ceea-467e-9575-6e3c8e9caeb2", duty: 0.6, remainingS: 1200
        ))
    }

    @Test("cards are sorted like equipmentRows sorts — by device id, not display name")
    func sortedById() {
        let devices = [
            LightingFixtures.device(id: "light-b", name: "Aardvark light"),
            LightingFixtures.device(id: "light-a", name: "Zebra light"),
        ]
        let cards = lightingCards(devices: devices, frames: [:])

        #expect(cards.map(\.id) == ["light-a", "light-b"])
    }

    // MARK: allowedDurations

    @Test("a 1-hour cap excludes the presets above it")
    func capExcludesAboveThePreset() {
        #expect(allowedDurations(maxRuntimeS: 3600) == [.fifteenMinutes, .oneHour])
    }

    @Test("no declared cap offers every preset")
    func noCapOffersEverything() {
        #expect(allowedDurations(maxRuntimeS: nil) == DurationPreset.allCases)
    }

    @Test("a cap below every preset offers nothing")
    func capBelowEverythingOffersNothing() {
        #expect(allowedDurations(maxRuntimeS: 600).isEmpty)
    }
}
