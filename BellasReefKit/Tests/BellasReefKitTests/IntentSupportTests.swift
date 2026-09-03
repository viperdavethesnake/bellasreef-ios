// Bella's Reef iOS — closed source.

import BellasReefAPI
import Testing

@testable import BellasReefKit

/// UX review D3: the App Intents surface is a second way into the same hold
/// the Lighting tab places, so the arithmetic and the words it answers with
/// live in the kit and get tested here rather than inside an `AppIntent`
/// (which needs the App Intents runtime, and so cannot run in this suite).
@Suite("Intent support")
struct IntentSupportTests {

    // MARK: Duration bounds

    @Test("the bounds are the hub's own, read off the spec")
    func boundsMatchTheSpec() {
        // BellasReefKit/Sources/BellasReefAPI/openapi.json,
        // components/schemas/OverrideRequest/properties/duration_s:
        // exclusiveMinimum 0, maximum 86400.
        #expect(IntentSupport.maxHoldDurationS == 86_400)
        #expect(IntentSupport.minHoldMinutes == 1)
        #expect(IntentSupport.maxHoldMinutes == 1440)
    }

    @Test("minutes become seconds inside the bounds, and nothing outside them")
    func minutesToSeconds() {
        #expect(IntentSupport.durationS(minutes: 1, maxRuntimeS: nil) == 60)
        #expect(IntentSupport.durationS(minutes: 15, maxRuntimeS: nil) == 900)
        #expect(IntentSupport.durationS(minutes: 1440, maxRuntimeS: nil) == 86_400)
        // exclusiveMinimum 0: a zero-length hold is not a hold.
        #expect(IntentSupport.durationS(minutes: 0, maxRuntimeS: nil) == nil)
        #expect(IntentSupport.durationS(minutes: -5, maxRuntimeS: nil) == nil)
        #expect(IntentSupport.durationS(minutes: 1441, maxRuntimeS: nil) == nil)
    }

    // MARK: The target's own runtime ceiling

    /// The API does not check a hold against the target's `max_runtime_s`
    /// (`create_override` gates on `observe_only` authority and on clock
    /// trust, and on nothing else), and hardware-io's `_runtime_deadline`
    /// latches a channel that outlives one, with no automatic path out. So
    /// this cap is the only thing in the way, and every door onto a hold has
    /// to go through it.
    @Test("the cap is the lower of the spec's ceiling and the light's own runtime")
    func cap() {
        // 18 h, the runtime an authoritative light declares by default.
        #expect(holdMinutesCap(maxRuntimeS: 64_800) == 1080)
        #expect(holdMinutesCap(maxRuntimeS: 3600) == 60)
        // Longer than the spec allows: the spec's ceiling wins.
        #expect(holdMinutesCap(maxRuntimeS: 172_800) == IntentSupport.maxHoldMinutes)
        // Undeclared, or nonsense: fall back to the spec's ceiling rather than
        // to no ceiling at all.
        #expect(holdMinutesCap(maxRuntimeS: nil) == IntentSupport.maxHoldMinutes)
        #expect(holdMinutesCap(maxRuntimeS: 0) == IntentSupport.maxHoldMinutes)
        // Truncated, never rounded up: 90 s is one whole minute, not two.
        #expect(holdMinutesCap(maxRuntimeS: 90) == 1)
    }

    @Test("a hold longer than the light's own runtime is refused, not clamped")
    func durationRespectsTheLightsRuntime() {
        #expect(IntentSupport.durationS(minutes: 1080, maxRuntimeS: 64_800) == 64_800)
        #expect(IntentSupport.durationS(minutes: 1081, maxRuntimeS: 64_800) == nil)
        // Inside the spec's 1440 but past this light's own 60.
        #expect(IntentSupport.durationS(minutes: 60, maxRuntimeS: 3600) == 3600)
        #expect(IntentSupport.durationS(minutes: 61, maxRuntimeS: 3600) == nil)
    }

    @Test("the refusal names the cap that actually applied")
    func minutesOutOfRangeCopy() {
        #expect(
            IntentSupport.minutesOutOfRange(maxRuntimeS: 64_800)
                == "A hold on this light has to be between 1 and 1080 minutes."
        )
        #expect(
            IntentSupport.minutesOutOfRange(maxRuntimeS: nil)
                == "A hold on this light has to be between 1 and 1440 minutes."
        )
    }

    // MARK: Percent to duty

    @Test("percent becomes the wire's 0…1 duty, refusing anything off the dial")
    func percentToDuty() {
        #expect(IntentSupport.duty(percent: 0) == 0)
        #expect(IntentSupport.duty(percent: 50) == 0.5)
        #expect(IntentSupport.duty(percent: 100) == 1)
        #expect(IntentSupport.duty(percent: -1) == nil)
        #expect(IntentSupport.duty(percent: 101) == nil)
    }

    @Test("duty is sent raw — the hub owns the floor, not this client")
    func dutyIsNotPreSnapped() {
        // `Dimming.minUsableDuty` is the hub's rule and the hub applies it.
        // Snapping here as well would mean two places deciding one thing, and
        // the Lighting tab does not do it either (`LightingView.hold()` sends
        // `proposedDuty / 100`).
        #expect(IntentSupport.duty(percent: 5) == 0.05)
    }

    // MARK: Dialogs

    @Test("a granted hold is reported with the light, the level and the length")
    func heldDialog() {
        #expect(
            IntentSupport.heldDialog(light: "Light 1", percent: 50, minutes: 15)
                == "Light 1 held at 50% for 15 minutes."
        )
    }

    @Test("one minute is singular")
    func heldDialogSingularMinute() {
        #expect(
            IntentSupport.heldDialog(light: "Sump", percent: 100, minutes: 1)
                == "Sump held at 100% for 1 minute."
        )
    }

    @Test("a sub-floor hold reports the level the hub will actually drive")
    func heldDialogBelowTheFloor() {
        // The hub snaps anything under 8 % to 0 before it reaches the pin
        // (`Dimming.minUsableDuty`). Saying "held at 5%" would be a sentence
        // the meter disagrees with.
        #expect(
            IntentSupport.heldDialog(light: "Light 1", percent: 5, minutes: 15)
                == "Light 1 held at 0% for 15 minutes. Below 8% this dimmer is off."
        )
        // A commanded 0 is hard off, not a snapped value — no footnote.
        #expect(
            IntentSupport.heldDialog(light: "Light 1", percent: 0, minutes: 15)
                == "Light 1 held at 0% for 15 minutes."
        )
        // The floor itself is usable and says nothing extra.
        #expect(
            IntentSupport.heldDialog(light: "Light 1", percent: 8, minutes: 15)
                == "Light 1 held at 8% for 15 minutes."
        )
    }

    @Test("release says which of the two things happened")
    func releaseDialogs() {
        #expect(IntentSupport.releasedDialog(light: "Light 1") == "Light 1 released.")
        #expect(IntentSupport.notHeldDialog(light: "Light 1") == "Light 1 wasn't held.")
    }

    // MARK: Refusals

    @Test("the refusal sentences are the ones the Lighting tab shows")
    func refusalCopy() {
        #expect(
            HoldRefusal.notCommandable.message
                == "This light is observe-only and can't be commanded from here."
        )
        #expect(
            HoldRefusal.clockUntrusted.message
                == "The hub's clock is not trusted yet — holds need a deadline."
        )
    }

    // MARK: The light predicate

    @Test("a light is an adopted light-role device, and nothing else")
    func lightPredicate() {
        #expect(isLight(Fixtures.device(id: "pca9685-0")))
        // Detached: unbind is not a delete, and a channel someone else could
        // reclaim is not this operator's to command.
        #expect(!isLight(Fixtures.device(id: "pca9685-1", adopted: false)))
        #expect(!isLight(Fixtures.device(id: "pca9685-2", role: "pump")))
        #expect(!isLight(Fixtures.device(id: "pca9685-3", role: nil)))
    }

    private enum Fixtures {
        static func device(
            id: String, role: String? = "light", adopted: Bool = true
        ) -> Components.Schemas.DeviceView {
            .init(
                actuatorClass: "dimmer",
                adopted: adopted,
                deviceId: id,
                displayName: "Fixture",
                driverId: "pca9685",
                enabled: true,
                kind: "actuator",
                maxRuntimeS: 3600,
                role: role
            )
        }
    }
}
