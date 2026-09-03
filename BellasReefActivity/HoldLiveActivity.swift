// Bella's Reef iOS — closed source.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Lock Screen and Dynamic Island presentation of a manual hold (UX
/// review D2): which light, what level, how it arrived, how long is left, and
/// a way to cancel it without opening the app.
///
/// `ActivityConfiguration(for:)` is ActivityKit's widget shape — the first
/// closure is the Lock Screen banner (and the Home Screen banner on devices
/// with no Dynamic Island), the second is the Dynamic Island's four
/// presentations
/// (https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).
///
/// System fonts and the system tint throughout. The app's teal lives in
/// `Theme` (`BellasReefKit`), and reaching it would mean linking the hub
/// client and the swift-openapi runtime into a widget extension — see
/// `HoldActivityAttributes` for why that trade is not worth an accent colour.
struct HoldLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HoldActivityAttributes.self) { context in
            lockScreen(context)
                .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.lightName)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.percent)%")
                        .font(.headline)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        detail(context)
                        Spacer(minLength: 12)
                        releaseButton(context)
                    }
                }
            } compactLeading: {
                Text("\(context.state.percent)%")
                    .monospacedDigit()
                    .accessibilityLabel("Held at \(context.state.percent) percent")
            } compactTrailing: {
                remaining(context)
            } minimal: {
                Text("\(context.state.percent)%")
                    .monospacedDigit()
                    .accessibilityLabel("Held at \(context.state.percent) percent")
            }
        }
    }

    // MARK: Lock Screen

    private func lockScreen(_ context: ActivityViewContext<HoldActivityAttributes>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.lightName)
                    .font(.headline)
                detail(context)
            }
            Spacer(minLength: 8)
            releaseButton(context)
        }
    }

    /// "50% · Snap · 7:59 left", or the honest version of it once the
    /// deadline has passed with no update.
    @ViewBuilder
    private func detail(_ context: ActivityViewContext<HoldActivityAttributes>) -> some View {
        HStack(spacing: 4) {
            Text("\(context.state.percent)% · \(context.attributes.transitionLabel) ·")
                .monospacedDigit()
            if context.isStale {
                // `staleDate` is the hold's own deadline, so past it the hub
                // has released this hold and nothing reached the app to say
                // so. Counting down below zero would be the banner inventing
                // a state the tank is not in.
                Text("past its deadline")
            } else {
                remaining(context)
                Text("left")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// The live countdown. `Text(timerInterval:countsDown:)` is the system's
    /// self-updating timer — a widget's view body is not re-rendered per
    /// second, so a hand-computed "8 min left" would freeze at whatever it
    /// said when the last update arrived.
    private func remaining(
        _ context: ActivityViewContext<HoldActivityAttributes>
    ) -> some View {
        let now = Date.now
        // A `ClosedRange` traps when its bounds are inverted, and a deadline
        // in the past is an ordinary thing for a banner to be holding.
        let range = now...max(context.state.expiresAt, now)
        return Text(timerInterval: range, countsDown: true)
            .monospacedDigit()
            .accessibilityLabel("Time left on this hold")
    }

    private func releaseButton(
        _ context: ActivityViewContext<HoldActivityAttributes>
    ) -> some View {
        // `ReleaseHoldIntent` is a `LiveActivityIntent`, so the system runs
        // it in the app's process, where the Keychain credential is. The
        // extension itself can talk to nothing.
        Button(intent: ReleaseHoldIntent(overrideId: context.attributes.overrideId)) {
            Text("Release")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Release the hold on \(context.attributes.lightName)")
    }
}
