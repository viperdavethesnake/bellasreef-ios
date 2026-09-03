// Bella's Reef iOS — closed source.

import AppIntents
import BellasReefKit
import Foundation

/// End a light's manual hold and let it go back to its schedule (UX review
/// D3).
///
/// Finding the hold is the whole difficulty. The Lighting tab reads it off
/// the state frame's `override`, but an intent woken by Shortcuts or by a
/// Live Activity button holds no socket and has no frame to read. The REST
/// route is `GET /api/v1/overrides` (`HubClient.overrides()`), whose
/// `OverrideView.target` is the device id — so the live hold for one light is
/// a filter, and its `id` is what `DELETE /api/v1/overrides/{id}` takes.
///
/// An override is never scoped to the client that placed it (the wire carries
/// no owner), so releasing here ends whichever hold is live, whoever placed
/// it — the same unconditional Release the Lighting card offers.
///
/// `LiveActivityIntent` because the protocol makes the system "launch the app
/// process in the background to perform the action"
/// (https://developer.apple.com/documentation/appintents/liveactivityintent),
/// which is what puts `perform()` next to the Keychain credential when
/// Shortcuts or Siri fires it from a locked phone.
///
/// The Live Activity's own Release button does **not** run this intent — it
/// runs `ReleaseHoldIntent` (`Shared/`), which is handed the exact override
/// id off the banner it was drawn on and needs no `LightEntity`, and so no
/// kit dependency in the widget extension. This one is the Shortcuts-facing
/// action, and it has to find the live hold itself.
struct ReleaseLightIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Release Light" }

    static var description: IntentDescription {
        IntentDescription("End a light's hold and let it go back to its schedule.")
    }

    /// See `HoldLightIntent.isDiscoverable`.
    static var isDiscoverable: Bool { true }

    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Light")
    var light: LightEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Release \(\.$light)")
    }

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = await HubClientFactory.remembered() else {
            throw IntentFailure.notPaired
        }

        let held: String?
        do {
            held = try await client.overrides().first { $0.target == light.id }?.id
        } catch {
            throw IntentFailure.hub(HumanError.describe(error))
        }

        guard let overrideId = held else {
            // Not an error: a light that is not held is a light already doing
            // what the schedule says.
            return .result(
                dialog: IntentDialog(
                    stringLiteral: IntentSupport.notHeldDialog(light: light.name)
                )
            )
        }

        // One release tail, shared with the Live Activity's own button:
        // release, a human sentence if the hub refuses, and the Lock Screen
        // banner down. That last step is not something frame reconciliation
        // could cover for — a shortcut run from a locked phone holds no
        // socket and may never draw a screen, which is also why
        // `HoldActivityController.end` re-checks the system's activity list
        // rather than trusting its in-memory handles.
        try await HoldRelease.run(overrideId: overrideId, using: client)
        return .result(
            dialog: IntentDialog(stringLiteral: IntentSupport.releasedDialog(light: light.name))
        )
    }
}
