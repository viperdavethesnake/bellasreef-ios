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

    var body: some View {
        Chart {
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
