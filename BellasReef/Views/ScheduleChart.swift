// Bella's Reef iOS — closed source.

import BellasReefKit
import Charts
import SwiftUI

/// One schedule, midnight to midnight (spec 2026-08-19 §iOS item 2):
/// the interpolated line, the real points marked, and — when `nowDate` is
/// given — a vertical now line. Read-only; editing is the points list.
struct ScheduleChart: View {
    let curve: ScheduleCurve
    /// `nil` on the editor preview: a draft has no meaningful "now".
    let nowDate: Date?
    /// The hub's reported duty at `nowDate` — wire truth, plotted as a
    /// distinct point so a slew-in-progress or a snapped-to-0 hold visibly
    /// leaves the curve rather than reading as the curve itself. `nil` on
    /// the editor preview (no `nowDate` either) and while the stream hasn't
    /// spoken yet.
    var reportedDuty: Double? = nil

    var body: some View {
        Chart {
            // Drawn first so the curve and points render over it, not under —
            // this is the sub-8% floor (`Dimming.minUsableDuty`): the hub
            // snaps any duty in this band to 0 before it reaches the pin, so
            // shading it teaches that a point drawn inside the band is not
            // what actually happens on the wire.
            RectangleMark(
                xStart: .value("Hour", 0), xEnd: .value("Hour", 24),
                yStart: .value("Brightness", 0),
                yEnd: .value("Brightness", Dimming.minUsableDuty * 100)
            )
            .foregroundStyle(Theme.floorBand)
            ForEach(curve.plotPoints, id: \.seconds) { point in
                LineMark(
                    x: .value("Hour", Double(point.seconds) / 3600),
                    y: .value("Brightness", point.duty * 100)
                )
                .foregroundStyle(Theme.accent)
            }
            ForEach(curve.points, id: \.seconds) { point in
                PointMark(
                    x: .value("Hour", Double(point.seconds) / 3600),
                    y: .value("Brightness", point.duty * 100)
                )
                .foregroundStyle(Theme.accent)
            }
            if let nowDate {
                RuleMark(x: .value("Now", Double(curve.secondsOfDay(for: nowDate)) / 3600))
                    .foregroundStyle(Theme.attention.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let nowDate, let reportedDuty {
                PointMark(
                    x: .value("Now", Double(curve.secondsOfDay(for: nowDate)) / 3600),
                    y: .value("Actual", reportedDuty * 100)
                )
                .foregroundStyle(Theme.attention)
                .symbolSize(60)
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hour = value.as(Double.self) {
                        Text("\(Int(hour)):00")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))%")
                    }
                }
            }
        }
    }
}
