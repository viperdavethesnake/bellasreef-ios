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
        expiresInS: Double = 1200,
        transition: Components.Schemas.OverrideContext.TransitionPayload = .ramp
    ) -> Components.Schemas.OverrideContext {
        .init(
            duty: duty,
            expiresAt: Date(timeIntervalSince1970: 1_786_343_122 + 1200),
            expiresInS: expiresInS,
            id: id,
            transition: transition
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
        let override = LightingFixtures.override(duty: 0.6, expiresInS: 1200, transition: .snap)
        let frame = LightingFixtures.frame(id: "light-1", duty: 0.6, override: override)
        let cards = lightingCards(devices: [device], frames: ["light-1": frame])

        #expect(cards.count == 1)
        #expect(cards[0].hold == LightingCard.ActiveHold(
            id: "8f14e45f-ceea-467e-9575-6e3c8e9caeb2", duty: 0.6,
            expiresAt: Date(timeIntervalSince1970: 1_786_343_122 + 1200),
            transition: .snap
        ))
    }

    @Test("the hold's transition comes off the frame, ramp and snap alike")
    func holdTransitionOffTheFrame() {
        let device = LightingFixtures.device(id: "light-1")
        for (wire, expected) in [
            (Components.Schemas.OverrideContext.TransitionPayload.ramp, HubClient.HoldTransition.ramp),
            (.snap, .snap),
        ] {
            let frame = LightingFixtures.frame(
                id: "light-1", override: LightingFixtures.override(transition: wire))
            let cards = lightingCards(devices: [device], frames: ["light-1": frame])
            #expect(cards[0].hold?.transition == expected)
        }
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

    // MARK: - Schedules

    private func scheduleView(
        name: String, assignedTo channels: [String], zone: String = "UTC",
        points: [Components.Schemas.SchedulePoint] = [
            .init(at: "08:00:00", duty: 0.0), .init(at: "20:00:00", duty: 0.6),
        ]
    ) -> Components.Schemas.ScheduleView {
        .init(
            anchor: .clock, assignedChannels: channels,
            id: "id-\(name)", name: name, points: points, zone: zone
        )
    }

    @Test("a card carries the schedule assigned to its channel")
    func scheduleAttaches() {
        let cards = lightingCards(
            devices: [LightingFixtures.device(id: "pi-pwm-0")],
            frames: [:],
            schedules: [scheduleView(name: "Reef day", assignedTo: ["pi-pwm-0"])]
        )
        #expect(cards[0].schedule?.name == "Reef day")
        #expect(cards[0].schedule?.curve.points.count == 2)
    }

    @Test("no assignment, no schedule — and an unparseable one renders as absent, not as a guess")
    func scheduleAbsentOrUnreadable() {
        let unassigned = lightingCards(
            devices: [LightingFixtures.device(id: "pi-pwm-0")],
            frames: [:],
            schedules: [scheduleView(name: "Reef day", assignedTo: ["pi-pwm-1"])]
        )
        #expect(unassigned[0].schedule == nil)

        let badZone = lightingCards(
            devices: [LightingFixtures.device(id: "pi-pwm-0")],
            frames: [:],
            schedules: [scheduleView(name: "Reef day", assignedTo: ["pi-pwm-0"], zone: "Neptune/Trench")]
        )
        #expect(badZone[0].schedule == nil)
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

/// `effectiveHold(...)` (LightingCards.swift) is the precedence decision the
/// Lighting tab's card view makes every render: frame vs. a client's own
/// optimistic grant vs. ids it already knows are stale. Extracted to here
/// and pinned by test (review round 2, 2026-08-15) after two bugs were found
/// in this exact seam while it lived as a view-local computed property —
/// C1 (a naturally-expiring hold rendering forever as a phantom) and I1 (a
/// same-duty re-hold's stale frame outranking the fresh grant that actually
/// superseded it).
@Suite("Effective hold precedence")
struct EffectiveHoldTests {
    static let now = Date(timeIntervalSince1970: 1_786_343_122)

    private static func hold(
        id: String, duty: Double = 0.5, expiresIn seconds: Double
    ) -> LightingCard.ActiveHold {
        .init(id: id, duty: duty, expiresAt: now.addingTimeInterval(seconds), transition: .ramp)
    }

    @Test("a frame with a hold wins over an optimistic one, even when both are present")
    func frameSpeaksRetiresOptimistic() {
        let frameHold = Self.hold(id: "frame-id", expiresIn: 600)
        let optimistic = Self.hold(id: "optimistic-id", expiresIn: 3600)

        let result = effectiveHold(
            frameHold: frameHold, optimisticHold: optimistic, releasedIDs: [], now: Self.now
        )

        #expect(result == frameHold)
    }

    @Test("an optimistic hold past its own deadline is absent, not a phantom")
    func expiredOptimisticIsAbsent() {
        let optimistic = Self.hold(id: "optimistic-id", expiresIn: -1)

        let result = effectiveHold(
            frameHold: nil, optimisticHold: optimistic, releasedIDs: [], now: Self.now
        )

        #expect(result == nil)
    }

    @Test("a same-duty re-hold hides the stale frame hold and shows the fresh optimistic one")
    func supersedeHidesOldShowsNew() {
        // The engine's deadband can leave the frame reporting the previous
        // hold for a while after a same-duty re-hold — `hold()` in the view
        // seeds `releasedIDs` with exactly the id below to compensate.
        let staleFrameHold = Self.hold(id: "old-id", expiresIn: 60)
        let freshOptimistic = Self.hold(id: "new-id", expiresIn: 3600)

        let result = effectiveHold(
            frameHold: staleFrameHold, optimisticHold: freshOptimistic,
            releasedIDs: ["old-id"], now: Self.now
        )

        #expect(result == freshOptimistic)
    }

    @Test("an id this card has released is suppressed even if the frame still carries it")
    func releasedIDIsSuppressed() {
        let gone = Self.hold(id: "gone-id", expiresIn: 600)

        let result = effectiveHold(
            frameHold: gone, optimisticHold: gone, releasedIDs: ["gone-id"], now: Self.now
        )

        #expect(result == nil)
    }

    @Test("no frame and no optimistic hold is simply nothing held")
    func nothingHeldIsNil() {
        #expect(effectiveHold(frameHold: nil, optimisticHold: nil, releasedIDs: [], now: Self.now) == nil)
    }
}
