// Bella's Reef iOS — closed source.

import AppIntents
import BellasReefKit
import Foundation

/// How a hold arrives and how it leaves, as a Shortcuts parameter.
///
/// A thin mirror of `HubClient.HoldTransition`: `AppEnum` needs a type it can
/// annotate with display representations, and the kit enum is not the App
/// Intents framework's to decorate. The mapping below is the only place the
/// two meet.
enum HoldTransitionAppEnum: String, AppEnum {
    case snap
    case ramp

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Transition" }

    static var caseDisplayRepresentations: [HoldTransitionAppEnum: DisplayRepresentation] {
        [.snap: "Snap", .ramp: "Ramp"]
    }

    var transition: HubClient.HoldTransition {
        switch self {
        case .snap: .snap
        case .ramp: .ramp
        }
    }
}

/// Hold a light at a level for a while, from Siri, Spotlight or Shortcuts
/// (UX review D3).
///
/// The same command the Lighting tab's Hold button places, through the same
/// `HubClient.hold` — this adds a second door, not a second control path.
///
/// Also a `LiveActivityIntent`. That protocol's purpose is background Live
/// Activity management, and the guarantee it carries is the one this needs:
/// "When the system executes the intent, it launches the app process in the
/// background to perform the action"
/// (https://developer.apple.com/documentation/appintents/liveactivityintent).
/// Without it, an intent invoked from a Live Activity's button runs in the
/// widget extension's process, which has no access to this app's Keychain
/// credential and so cannot talk to the hub at all. `ReleaseLightIntent` and
/// `ReleaseHoldIntent` (the Live Activity's own Release button) conform for
/// the same reason; all three behave alike.
struct HoldLightIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Hold Light" }

    static var description: IntentDescription {
        IntentDescription(
            "Hold a light at a set brightness for a set time, then let it go back to its schedule."
        )
    }

    /// `LiveActivityIntent` inherits `SystemIntent`, so say plainly that this
    /// is still meant to appear in Shortcuts and Spotlight. True is the
    /// framework default
    /// (https://developer.apple.com/documentation/appintents/appintent/isdiscoverable);
    /// it is pinned here so a future protocol conformance cannot quietly take
    /// the shortcut away.
    static var isDiscoverable: Bool { true }

    /// Nothing to show, so nothing to open. The hold happens in the
    /// background and the dialog is the whole answer.
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Light")
    var light: LightEntity

    @Parameter(title: "Brightness", inclusiveRange: (0, 100))
    var percent: Int

    /// 1…1440 is the spec's own `duration_s` window
    /// (`IntentSupport.minHoldMinutes`…`maxHoldMinutes`), spelled as literals
    /// because `inclusiveRange:` takes only compile-time constants ("expect a
    /// compile-time constant literal").
    ///
    /// Deliberately the *wider* of the two ceilings. Which one actually
    /// applies depends on the light that gets resolved — a channel's own
    /// `max_runtime_s` is usually shorter (18 h, so 1080 minutes) — and an
    /// attribute cannot see a parameter. `perform()` is where the real cap is
    /// checked, so a minute count the picker allowed and the light will not
    /// take comes back as a sentence naming that light's own limit.
    @Parameter(title: "Minutes", default: 15, inclusiveRange: (1, 1440))
    var minutes: Int

    @Parameter(title: "Transition", default: .snap)
    var transition: HoldTransitionAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Hold \(\.$light) at \(\.$percent)% for \(\.$minutes) minutes") {
            \.$transition
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Check the bounds here rather than trusting the picker: a shortcut
        // can be handed a value from an earlier step that never went through
        // a slider.
        guard let duty = IntentSupport.duty(percent: percent) else {
            throw IntentFailure.outOfRange("Brightness has to be between 0 and 100 percent.")
        }
        // And this is the only place the *light's own* ceiling can be applied,
        // because it is not known until the entity resolves. Nothing below
        // this client applies it: `create_override` gates on authority and
        // clock trust alone, and hardware-io latches a channel that outlives
        // `max_runtime_s`.
        guard let durationS = IntentSupport.durationS(
            minutes: minutes, maxRuntimeS: light.maxRuntimeS
        ) else {
            throw IntentFailure.outOfRange(
                IntentSupport.minutesOutOfRange(maxRuntimeS: light.maxRuntimeS)
            )
        }
        guard let client = await HubClientFactory.remembered() else {
            throw IntentFailure.notPaired
        }

        let outcome: HubClient.HoldOutcome
        do {
            // `reason` is what the hub's audit log records this hold as, which
            // is how an operator reading the log later can tell a shortcut
            // apart from a tap on the Lighting tab ("manual").
            outcome = try await client.hold(
                target: light.id, duty: duty, durationS: durationS, reason: "intent",
                transition: transition.transition
            )
        } catch {
            throw IntentFailure.hub(HumanError.describe(error))
        }

        switch outcome {
        case .granted:
            return .result(
                dialog: IntentDialog(
                    stringLiteral: IntentSupport.heldDialog(
                        light: light.name, percent: percent, minutes: minutes
                    )
                )
            )
        case .notCommandable:
            throw IntentFailure.refused(.notCommandable)
        case .clockUntrusted:
            throw IntentFailure.refused(.clockUntrusted)
        }
    }
}
