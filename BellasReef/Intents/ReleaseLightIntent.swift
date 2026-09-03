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

        do {
            // `.released` and `.alreadyReleased` are the same news — the hold
            // is gone — so both say so. A 404 here just means it expired
            // between the list and the delete.
            _ = try await client.release(overrideId: overrideId)
        } catch {
            throw IntentFailure.hub(HumanError.describe(error))
        }
        // The hold is gone, so its Lock Screen banner has to go too (UX
        // review D2). Frame reconciliation would eventually catch this, but
        // only while the app is running with a live socket — a shortcut run
        // from a locked phone has neither.
        await HoldActivityController.shared.end(overrideId: overrideId)
        return .result(
            dialog: IntentDialog(stringLiteral: IntentSupport.releasedDialog(light: light.name))
        )
    }
}
