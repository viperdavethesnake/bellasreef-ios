// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

/// The B3 status strip: the hub's pulse, carried on every tab.
///
/// David ruled on 2026-09-02 for option 1 of the B3 brainstorm — three states,
/// teal/amber, no taps, no menu, and no glass beyond what
/// `tabViewBottomAccessory` gives for free — and approved the look on
/// 2026-09-03 off simulator captures.
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
        StatusStrip.state(monitor: monitor, preferred: primarySensorId, now: now)
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
