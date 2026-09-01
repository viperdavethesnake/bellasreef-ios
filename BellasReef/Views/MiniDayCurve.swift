// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

/// The card's day-at-a-glance: the assigned curve midnight-to-midnight as a
/// `Path` (the `Sparkline` idiom — Charts stays on the detail and History
/// screens), with a now dot plotted at the *wire* duty, not the curve's own
/// value. When the two diverge — a hold, a slew still in flight, the <8%
/// snap — the dot visibly leaves the line, which is exactly the information
/// (spec 2026-08-19 §iOS item 1). No frame yet, no dot.
struct MiniDayCurve: View {
    let curve: ScheduleCurve
    /// Seconds since local midnight in the schedule's zone
    /// (`curve.secondsOfDay(for:)` at the caller's tick).
    let nowSeconds: Int
    /// The hub's reported duty — wire truth. `nil` while the stream has not
    /// spoken for this channel.
    let nowDuty: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let plotted = curve.plotPoints

            // The same sub-8% floor `ScheduleChart` shades
            // (`Dimming.minUsableDuty`): the hub snaps any duty in this band
            // to 0 before it reaches the pin, so a point plotted inside it
            // here — without the shading — would show something that never
            // actually happens on the wire.
            Rectangle()
                .fill(Theme.floorBand)
                .frame(width: width, height: height * CGFloat(Dimming.minUsableDuty))
                .position(x: width / 2, y: height - (height * CGFloat(Dimming.minUsableDuty)) / 2)

            Path { path in
                for (index, point) in plotted.enumerated() {
                    let x = width * CGFloat(point.seconds) / 86_400
                    let y = height * (1 - CGFloat(point.duty))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Theme.accent.opacity(0.5), lineWidth: 1.5)

            if let nowDuty {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
                    .position(
                        x: width * CGFloat(nowSeconds) / 86_400,
                        y: height * (1 - CGFloat(nowDuty))
                    )
            }
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let scheduled = Int((curve.duty(atSecondsToday: nowSeconds) * 100).rounded())
        if let nowDuty {
            return "Day curve. Scheduled \(scheduled) percent now, actual \(Int((nowDuty * 100).rounded())) percent."
        }
        return "Day curve. Scheduled \(scheduled) percent now."
    }
}
