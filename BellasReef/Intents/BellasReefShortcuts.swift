// Bella's Reef iOS — closed source.

import AppIntents

/// The shortcuts the system offers without the operator building anything.
///
/// Two, matching the two intents. A phrase must contain
/// `\(.applicationName)` or the system will not register it
/// (https://developer.apple.com/documentation/appintents/appshortcut), so
/// every phrase here names the app; "Bella's Reef" is the app name the
/// system substitutes.
struct BellasReefShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: HoldLightIntent(),
            phrases: [
                "Hold a light in \(.applicationName)",
                "Hold a \(.applicationName) light"
            ],
            shortTitle: "Hold Light",
            systemImageName: "lightbulb.max"
        )
        AppShortcut(
            intent: ReleaseLightIntent(),
            phrases: [
                "Release a light in \(.applicationName)",
                "Release a \(.applicationName) light"
            ],
            shortTitle: "Release Light",
            systemImageName: "lightbulb"
        )
    }
}
