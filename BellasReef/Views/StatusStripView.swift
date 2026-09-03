// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

/// The B3 status strip: the hub's pulse, carried on every tab.
///
/// PROTOTYPE (branch `proto/status-strip`). David ruled on 2026-09-02 for
/// option 1 of the B3 brainstorm — three states, teal/amber, no taps, no menu,
/// and no glass beyond what `tabViewBottomAccessory` gives for free — built on
/// a branch so the look can be judged on a screen rather than in prose.
///
/// The view is deliberately thin: `StatusStrip.state` decides what is true and
/// `StatusStripState` owns the copy, both in the Kit and both tested. What is
/// left here is a glyph, a line, and the rule that it must never truncate.
struct StatusStripView: View {
    /// `nil` before a hub is adopted — nothing to report, so nothing shows.
    var monitor: TankMonitor?
    /// The operator's chosen probe, when there is one.
    var primarySensorId: String?
    var unit: TemperatureUnitPreference = .automatic
    /// Previews and the capture harness pin a state; the app never does.
    var pinned: StatusStripState?

    @ScaledMetric(relativeTo: .subheadline) private var dotSize: CGFloat = 7

    private var font: Font { .system(.subheadline, design: .rounded).monospacedDigit() }

    var body: some View {
        // The same clock the Tank tab's status line runs on, and for the same
        // reason: staleness and age arrive through the *absence* of frames, so
        // nothing mutates observed state and nothing would redraw. Not a second
        // staleness timer — the monitor still decides what stale means; this
        // only asks it again.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            strip(state(now: context.date), now: context.date)
        }
    }

    /// Straight from the monitor, on every tick — the Kit adapter the tab view
    /// reads too, so the accessory's existence and its contents can never come
    /// from two different answers.
    private func state(now: Date) -> StatusStripState {
        pinned ?? StatusStrip.state(monitor: monitor, preferred: primarySensorId, now: now)
    }

    @ViewBuilder
    private func strip(_ state: StatusStripState, now: Date) -> some View {
        if let tone = state.tone, let full = state.text(unit: unit, now: now) {
            let compact = state.compactText(unit: unit) ?? full
            HStack(spacing: 6) {
                glyph(state, tone: tone)
                // Never truncated: the full line, then the same line with the
                // number or the age dropped, then that wrapped. At the largest
                // accessibility size on the narrowest phone the third is what
                // renders, and it still says which of the three states this is
                // — which is the whole job.
                ViewThatFits(in: .horizontal) {
                    Text(full).lineLimit(1)
                    Text(compact).lineLimit(1)
                    Text(compact).lineLimit(2)
                }
                .font(font)
                .foregroundStyle(tone.color)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .center)
            // The accessory brings its own material, and the system makes it
            // opaque under Reduce Transparency. Adding a background of our own
            // would both fight that and break the brief's "no glass beyond
            // what the accessory gives for free".
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.spokenLabel(unit: unit, now: now) ?? "")
        }
    }

    /// A symbol, not a `Circle` shape: `.symbolEffect` only animates SF
    /// Symbols, and a state change is worth one beat of motion (UX review B8).
    /// Both glyphs scale with the text — the dot from a `@ScaledMetric`,
    /// because a fixed 7pt dot beside accessibility-sized type reads as dirt
    /// on the screen.
    @ViewBuilder
    private func glyph(_ state: StatusStripState, tone: HealthTone) -> some View {
        if let symbol = state.symbolName {
            Image(systemName: symbol)
                .font(symbol == "circle.fill" ? .system(size: dotSize) : font)
                .foregroundStyle(tone.color)
                .symbolEffect(.pulse, options: .nonRepeating, value: state)
        }
    }
}

/// Prototype scaffolding, and nothing else.
///
/// `-proto-strip live|stale|unreachable|hidden` pins the strip so all three
/// states can be captured in the simulator with no hub in the loop — the
/// screenshot is the deliverable David rules from, and two of the three states
/// otherwise need a hub to be stopped. Debug-only, the same way
/// `-uitest-reset-pairing` is: a release build has no such argument, so nothing
/// a shipped binary can be handed will pin the strip to a state the hub is not
/// in. It goes when the harness goes.
enum StatusStripDemo {
    static var requested: StatusStripState? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-proto-strip"), flag + 1 < args.count else {
            return nil
        }
        switch args[flag + 1] {
        case "live": return .live(reading: 25.9444)  // 78.7 °F
        case "stale": return .stale
        case "unreachable": return .unreachable(since: Date().addingTimeInterval(-260))
        case "hidden": return .hidden
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

#if DEBUG
/// The strip in its own tab bar, so a preview shows the real accessory rather
/// than a floating `HStack`.
private struct StripPreview: View {
    let state: StatusStripState

    var body: some View {
        TabView {
            Tab("Tank", systemImage: "drop.fill") { Color.clear.reefBackground() }
            Tab("Lighting", systemImage: "lightbulb.fill") { Color.clear.reefBackground() }
            Tab("History", systemImage: "chart.bar.fill") { Color.clear.reefBackground() }
            Tab("System", systemImage: "gearshape") { Color.clear.reefBackground() }
        }
        .tabViewBottomAccessory { StatusStripView(pinned: state) }
        .tint(Theme.accent)
    }
}

#Preview("live") { StripPreview(state: .live(reading: 25.9444)) }
#Preview("stale") { StripPreview(state: .stale) }
#Preview("unreachable") {
    StripPreview(state: .unreachable(since: Date().addingTimeInterval(-260)))
}
#Preview("hidden") { StripPreview(state: .hidden) }
#endif
