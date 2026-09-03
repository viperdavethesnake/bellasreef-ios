// Bella's Reef iOS — closed source.

import AppIntents
import Foundation

/// What the Live Activity's Release button runs (UX review D2).
///
/// Compiled into BOTH targets, which is the App Intents rule for an intent a
/// widget's `Button(intent:)` names: the extension needs the type to build
/// the button, the app needs it to perform the action.
///
/// Only the *declaration* is shared. The body is behind `BELLASREEF_APP`
/// (set on the app target in `project.yml`) so the extension keeps no
/// dependency on `BellasReefKit` or the swift-openapi runtime — a widget
/// extension that links the hub client to draw a countdown is carrying
/// several megabytes it can never use, and Live Activities are the tightest
/// memory budget on the platform. The extension's copy of `perform()` is
/// never executed: `LiveActivityIntent` makes the system "launch the app
/// process in the background to perform the action"
/// (https://developer.apple.com/documentation/appintents/liveactivityintent),
/// which is the same guarantee `HoldLightIntent` and `ReleaseLightIntent`
/// already rely on, and the only process holding the Keychain credential is
/// the app's.
///
/// Distinct from `ReleaseLightIntent`, which is the Shortcuts-facing action:
/// that one takes a `LightEntity` and has to look the live hold up over REST.
/// This one is handed the exact override id off the banner it is drawn on, so
/// it releases that id and nothing else — a hold that was superseded while
/// the banner was on screen must not have its replacement released by a tap
/// meant for the old one.
struct ReleaseHoldIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Release Hold" }

    static var description: IntentDescription {
        IntentDescription("End the hold shown on a Bella's Reef Live Activity.")
    }

    /// Hidden from Shortcuts and Spotlight. This is a button on a banner,
    /// not an action worth building a shortcut out of — `ReleaseLightIntent`
    /// is that action, and offering both would put two near-identical
    /// "Release" rows in the operator's library.
    static var isDiscoverable: Bool { false }

    /// The whole point is that the banner's button does not send the
    /// operator into the app.
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Hold")
    var overrideId: String

    init() {}

    init(overrideId: String) {
        self.overrideId = overrideId
    }

    func perform() async throws -> some IntentResult {
        #if BELLASREEF_APP
        try await HoldRelease.run(overrideId: overrideId)
        #endif
        return .result()
    }
}
