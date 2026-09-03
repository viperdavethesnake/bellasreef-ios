// Bella's Reef iOS — closed source.

import Foundation

/// Why a hold did not happen, and the one sentence each reason gets.
///
/// The Lighting tab and the Hold app intent are two doors onto one command
/// (`HubClient.hold`), so they answer a refusal with the same words. This is
/// where those words live; both call sites read them from here rather than
/// carrying a private copy that drifts.
///
/// `HubClient.HoldOutcome` deliberately keeps these as distinct cases instead
/// of a thrown error — a clock the hub does not trust is a quiet state to
/// render, not a failure to retry into an identical result — so the mapping
/// from outcome to sentence is a caller's job and this is the shared half of
/// it.
public enum HoldRefusal: Sendable, Equatable {
    /// 409 — `observe_only` authority (device-classes.md §2.3).
    case notCommandable
    /// 503 — the hub's clock is not synchronised, and an override is a
    /// deadline.
    case clockUntrusted

    public var message: String {
        switch self {
        case .notCommandable:
            "This light is observe-only and can't be commanded from here."
        case .clockUntrusted:
            "The hub's clock is not trusted yet — holds need a deadline."
        }
    }
}

/// The arithmetic and the phrasing behind the App Intents surface (UX review
/// D3), kept out of the intents themselves.
///
/// An `AppIntent` cannot be exercised without the App Intents runtime and
/// lives in the app target, so anything decided inside one is untestable by
/// this package. Everything here is a pure function over numbers and names,
/// and the intents are left thin enough to read as plumbing.
public enum IntentSupport {

    // MARK: Duration

    /// The longest hold the hub will accept, in seconds.
    ///
    /// Read from the contract, not chosen here:
    /// `BellasReefKit/Sources/BellasReefAPI/openapi.json`,
    /// `components/schemas/OverrideRequest/properties/duration_s` carries
    /// `exclusiveMinimum: 0` and `maximum: 86400`. A value outside that is a
    /// 422 the operator would have to decode from a validation envelope.
    public static let maxHoldDurationS: Double = 86_400

    /// The intent asks for minutes because that is the unit a person says out
    /// loud. One minute is the smallest whole minute above the spec's
    /// exclusive zero.
    public static let minHoldMinutes = 1
    public static let maxHoldMinutes = Int(maxHoldDurationS / 60)

    /// Seconds for `HubClient.hold(durationS:)`, or nil when the request is
    /// longer than this target will accept.
    ///
    /// `maxRuntimeS` is the resolved target's own declared ceiling, and it is
    /// a required argument on purpose. The API does **not** check a hold
    /// against `max_runtime_s` — `create_override` gates on `observe_only`
    /// authority and on clock trust, and on nothing else — and hardware-io's
    /// `_runtime_deadline` latches a channel that outlives one, with no
    /// automatic path back out. A caller that forgot to pass it would be the
    /// whole bug. `holdMinutesCap` is the one rule, shared with the Lighting
    /// tab's custom-duration field.
    ///
    /// Nil rather than a clamp: silently holding for 18 hours because someone
    /// asked for 30 is not the command they gave, and a hold is a deadline on
    /// a real fixture.
    public static func durationS(minutes: Int, maxRuntimeS: Double?) -> Double? {
        guard minutes >= minHoldMinutes,
              minutes <= holdMinutesCap(maxRuntimeS: maxRuntimeS) else { return nil }
        return Double(minutes) * 60
    }

    /// Why that duration was refused — the spoken twin of the Lighting tab's
    /// "Enter 1–1080 minutes." hint, naming the cap that actually applied.
    public static func minutesOutOfRange(maxRuntimeS: Double?) -> String {
        "A hold on this light has to be between \(minHoldMinutes) and "
            + "\(holdMinutesCap(maxRuntimeS: maxRuntimeS)) minutes."
    }

    // MARK: Level

    /// A whole percent off the dial as the wire's 0…1 duty, or nil when it is
    /// not a percent.
    ///
    /// Not pre-snapped to `Dimming.minUsableDuty`: the floor is the hub's rule
    /// and the hub applies it, the same way `LightingView.hold()` sends the
    /// slider's raw value. Two places applying one rule is how they end up
    /// disagreeing.
    public static func duty(percent: Int) -> Double? {
        guard percent >= 0, percent <= 100 else { return nil }
        return Double(percent) / 100
    }

    // MARK: Dialogs

    /// What Siri or Shortcuts says back after a granted hold.
    ///
    /// Reports the level the hub will actually drive, not the one that was
    /// asked for: anything under the 8 % floor is snapped to 0 before it
    /// reaches the pin (`Dimming.snapPercent`, proven end to end at Stage 2),
    /// so "held at 5%" would be a sentence a meter disagrees with. The
    /// footnote appears only when a non-zero request was snapped — a
    /// commanded 0 is hard off and needs no explaining.
    public static func heldDialog(light: String, percent: Int, minutes: Int) -> String {
        let effective = Int(Dimming.snapPercent(Double(percent)))
        let length = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        let line = "\(light) held at \(effective)% for \(length)."
        guard percent > 0, effective == 0 else { return line }
        return line + " Below \(Dimming.percent(Dimming.minUsableDuty))% this dimmer is off."
    }

    public static func releasedDialog(light: String) -> String {
        "\(light) released."
    }

    /// Nothing was holding this light, so nothing was released. Said plainly
    /// rather than thrown: asking to release an unheld light is not an error,
    /// it is a light that is already following its schedule.
    public static func notHeldDialog(light: String) -> String {
        "\(light) wasn't held."
    }
}
