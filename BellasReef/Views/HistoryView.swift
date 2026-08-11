// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import Charts
import SwiftUI

/// Charts live here (design brief §3). The Tank tab keeps a sparkline; this is
/// the tab that answers "what has it been doing".
///
/// All five §7.1 states are distinct: loading, empty (the store has nothing for
/// this window), populated, error, and refreshing via pull-to-refresh.
struct HistoryTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var history: HistoryModel?

    var body: some View {
        NavigationStack {
            Group {
                if let history {
                    content(history)
                } else {
                    ContentUnavailableView(
                        "Not connected",
                        systemImage: "wifi.slash",
                        description: Text("Pair with a hub to see history.")
                    )
                }
            }
            .reefBackground()
            .navigationTitle("History")
        }
        .task {
            if history == nil, let client = model.client, let catalog = model.catalog {
                let made = HistoryModel(client: client, catalog: catalog)
                history = made
                await made.load()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // REST data does not push; returning to the app is when the
            // operator expects it to be current.
            if phase == .active { Task { await history?.load() } }
        }
    }

    @ViewBuilder
    private func content(_ history: HistoryModel) -> some View {
        @Bindable var history = history

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RangePicker(selection: $history.range)

                switch history.state {
                case .idle, .loading:
                    Loading()
                case let .failed(why):
                    Failure(why: why) { Task { await history.load() } }
                case .empty:
                    Empty(range: history.range)
                case .loaded:
                    ForEach(history.traces) { trace in
                        TraceChart(trace: trace, history: history)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await history.load() }
    }
}

struct RangePicker: View {
    @Binding var selection: HistoryRange

    var body: some View {
        Picker("Range", selection: $selection) {
            ForEach(HistoryRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        // 44pt target (§7.4); a segmented control is shorter by default.
        .frame(minHeight: 44)
    }
}

struct Loading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView()
            Text("Reading history from the hub…")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
    }
}

struct Empty: View {
    let range: HistoryRange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing recorded")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            // Distinct from a failure on purpose: an empty store and an
            // unreachable one look identical on a blank chart, and only one of
            // them is worth getting out of bed for.
            Text("The hub has no telemetry for the last \(range.label). "
                 + "History starts accumulating once the hub is running.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
    }
}

struct Failure: View {
    let why: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Could not load history", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Theme.attention)
            Text(why)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }
}

/// One device's chart: envelope, mean line, and alert bands.
struct TraceChart: View {
    let trace: HistoryTrace
    let history: HistoryModel

    @Environment(AppModel.self) private var model

    private var unit: TemperatureUnitPreference {
        model.preferences?.temperatureUnit ?? .automatic
    }

    /// Convert for display; duty is a ratio and passes through as a percentage.
    private func display(_ value: Double) -> Double {
        guard trace.isTemperature else { return value * 100 }
        return TemperatureDisplay.measurement(celsius: value, as: unit).value
    }

    private var axisLabel: String {
        trace.isTemperature ? TemperatureDisplay.symbol(for: unit) : "%"
    }

    /// The visible y-range, from the envelope rather than from zero.
    ///
    /// Charts anchors a numeric axis at zero by default, which for a tank at
    /// 77 °F squeezes every reading into the top few percent of the plot and
    /// hides exactly the variation the chart exists to show. The domain is
    /// taken from `minimum`/`maximum` — the envelope, not the mean, so a spike
    /// is inside the axis rather than clipped by it — with a tenth of the span
    /// as breathing room and a floor on that padding so a dead-flat trace does
    /// not collapse to a zero-height axis.
    ///
    /// Duty is different and stays 0–100: percentage of full output is a scale
    /// with a real zero, and rescaling it would make a channel at 2% look like
    /// a channel at full.
    private var yDomain: ClosedRange<Double> {
        guard trace.isTemperature else { return 0...100 }
        let values = trace.segments.flatMap(\.buckets).flatMap {
            [display($0.minimum), display($0.maximum)]
        }
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        let padding = max((high - low) * 0.1, 0.5)
        return (low - padding)...(high + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(trace.name)
                    .font(Theme.sectionTitle)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text(axisLabel)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }

            Chart {
                // Bands first, so the curve draws over them rather than under.
                ForEach(history.bands(for: trace.deviceId)) { band in
                    let tint = band.alertClass == .silence ? Theme.silence : Theme.attention
                    let solidEnd = band.settledEnd(lastData: history.lastDataAt)

                    // The part backed by data. Capped at 0.16, and the model
                    // merges same-class bands, so at most two of these can ever
                    // overlap — a ceiling near 0.30, which still lets the trace
                    // read through instead of disappearing into a slab.
                    if solidEnd > band.start {
                        RectangleMark(
                            xStart: .value("from", band.start),
                            xEnd: .value("to", solidEnd)
                        )
                        .foregroundStyle(tint.opacity(0.16))
                    }

                    // Past the last sample an ongoing band is inference, not
                    // record: we believe it continues because nothing has said
                    // otherwise. Fading says that. Dropping it would read as
                    // "resolved", which is the opposite of what is known.
                    if band.isOngoing, band.end > solidEnd {
                        RectangleMark(
                            xStart: .value("from", solidEnd),
                            xEnd: .value("to", band.end)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [tint.opacity(0.16), tint.opacity(0.02)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    }

                    // An ongoing band gets an edge at its leading boundary. A
                    // bounded episode is closed on both sides by its own fill;
                    // an open one runs off the chart, and without this it looks
                    // identical to one that happened to clear just now.
                    if band.isOngoing {
                        RuleMark(x: .value("from", band.start))
                            .foregroundStyle(tint.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    }
                }

                ForEach(trace.segments) { segment in
                    // The envelope. Without it a spike inside a bucket is
                    // averaged away, and an alert band would sit over a curve
                    // that never appears to breach.
                    ForEach(segment.buckets, id: \.at) { bucket in
                        AreaMark(
                            x: .value("t", bucket.at),
                            yStart: .value("low", display(bucket.minimum)),
                            yEnd: .value("high", display(bucket.maximum)),
                            series: .value("band", "band-\(segment.id)")
                        )
                        .foregroundStyle(Theme.accent.opacity(0.18))
                        .interpolationMethod(.monotone)
                    }
                    // One line per segment: a gap in the data is a gap in the
                    // line, never a straight edge across missing time.
                    ForEach(segment.buckets, id: \.at) { bucket in
                        LineMark(
                            x: .value("t", bucket.at),
                            y: .value("avg", display(bucket.average)),
                            series: .value("line", "line-\(segment.id)")
                        )
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: yDomain)
            // The x domain is the range the operator picked, not the extent of
            // whatever data came back. Letting Charts infer it meant 7D drew the
            // last four hours across the full width whenever the hub had been
            // down — a chart that silently redefines "7 days" as "everything I
            // have" is how a gap stops looking like a gap.
            .chartXScale(domain: history.window ?? Date.distantPast...Date())
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis {
                AxisMarks(values: history.range.axisStride) { _ in
                    AxisGridLine()
                    AxisTick()
                    // `.greedy`, because the default drops a label rather than
                    // let it overlap — and the label it drops is the last one,
                    // whose tick sits on the plot edge. On a week view that is
                    // the label naming today, which is the one an operator is
                    // most likely to be looking for. Trailing padding gives it
                    // somewhere to go; this stops Charts discarding it first.
                    AxisValueLabel(
                        format: history.range.axisFormat,
                        collisionResolution: .greedy
                    )
                }
            }
            // Room for the trailing axis label, taken from the PLOT rather than
            // added outside the chart. Charts centres the last label on its
            // tick, which sits on the plot's right edge, so half of it lands
            // outside the chart's bounds and is clipped there — "…" at 24H,
            // "T…" at 7D. Outer padding cannot reach it, because the clipping
            // happens inside. Insetting the plot moves the tick inward so the
            // whole label falls within the chart.
            //
            // The plot loses ~26pt of width. Worth it on an axis whose entire
            // job at 7D is naming which day you are looking at, and the day it
            // was dropping was today's.
            .chartPlotStyle { $0.padding(.trailing, 26) }
            .frame(height: 180)
            .accessibilityLabel(Self.spoken(trace: trace, history: history))

            Footnote(trace: trace, history: history)
        }
        .padding(.bottom, 8)
    }

    private static func spoken(trace: HistoryTrace, history: HistoryModel) -> String {
        let bands = history.bands(for: trace.deviceId).count
        let points = trace.segments.reduce(0) { $0 + $1.buckets.count }
        var said = "\(trace.name) history, \(points) points"
        if trace.segments.count > 1 { said += ", \(trace.segments.count - 1) gaps" }
        if bands > 0 { said += ", \(bands) alert episodes" }
        return said
    }
}

/// Says out loud what the chart is and is not claiming.
struct Footnote: View {
    let trace: HistoryTrace
    let history: HistoryModel

    /// Gap wording that survives a change of zoom.
    ///
    /// The same hour honestly reported "1 gap" at 1H and nothing at 6H, which
    /// read as the chart contradicting itself. It was not: a gap is a missing
    /// bucket, so an outage shorter than a bucket is not merely unreported, it
    /// is invisible — both samples land in the same bucket. Coarsen the range
    /// and small holes stop existing as far as the data can tell.
    ///
    /// So the footnote states the resolution it is speaking at, in both
    /// directions. "No gaps" without that qualifier is a claim the chart cannot
    /// support at 7D, and silence about it is what made the two answers look
    /// like a bug rather than a limit.
    private static func resolution(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded()))s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min" }
        return "\(Int((seconds / 3600).rounded()))h"
    }

    var body: some View {
        let gaps = max(0, trace.segments.count - 1)
        let bands = history.bands(for: trace.deviceId).count
        let floor = history.gapFloor.map(Self.resolution)

        HStack(spacing: 12) {
            if bands > 0 {
                Label(
                    bands == 1 ? "1 alert episode" : "\(bands) alert episodes",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(Theme.attention)
            }
            if gaps > 0 {
                // Named rather than left to be inferred from a broken line: a
                // gap means the hub recorded nothing, not that the tank was at
                // zero, and the difference matters.
                Label(
                    (gaps == 1 ? "1 gap — nothing recorded" : "\(gaps) gaps — nothing recorded")
                        + (floor.map { " (≥\($0))" } ?? ""),
                    systemImage: "chart.line.flattrend.xyaxis"
                )
                .foregroundStyle(Theme.tertiaryText)
            } else if let floor {
                Label(
                    "No gaps at this resolution (\(floor))",
                    systemImage: "chart.line.flattrend.xyaxis"
                )
                .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
        }
        .font(Theme.caption)
    }
}


/// Axis presentation for a range.
///
/// In the view layer, not in HistoryModel: `AxisMarkValues` is a Charts
/// type, and a model that imports a rendering framework to describe itself
/// has stopped being a model.
extension HistoryRange {
    /// Where the x-axis puts its labels.
    ///
    /// Stated per range rather than left to `.automatic`. Over seven days
    /// automatic labelling picks hours and renders seven identical-looking
    /// clusters of times with no way to tell Tuesday from Friday — the one
    /// question a week view exists to answer.
    var axisStride: AxisMarkValues {
        // `roundLowerBound` snaps ticks to clean calendar boundaries instead of
        // anchoring them to whenever the window happens to start. Two problems,
        // one fix.
        //
        // Readability: a 24H window opened at 10:08 was ticking at 4:08 PM and
        // labelling it "4 PM", which is a time that means nothing.
        //
        // And the missing trailing label. Anchored to the window start, the
        // last tick landed exactly on the upper bound, where Charts declines to
        // draw a label at all — neither greedy collision resolution nor
        // insetting the plot recovers it, because the tick is on the boundary
        // rather than merely near it. Rounded ticks never sit on the edge.
        switch self {
        case .hour: .stride(by: .minute, count: 15, roundLowerBound: true)
        case .sixHours: .stride(by: .hour, count: 1, roundLowerBound: true)
        case .day: .stride(by: .hour, count: 6, roundLowerBound: true)
        case .week: .stride(by: .day, count: 1, roundLowerBound: true)
        }
    }

    /// Matching label format: days get a weekday, everything shorter gets a clock.
    var axisFormat: Date.FormatStyle {
        switch self {
        case .week: .dateTime.weekday(.abbreviated)
        case .day: .dateTime.hour()
        default: .dateTime.hour().minute()
        }
    }

}
