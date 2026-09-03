// Bella's Reef iOS — closed source.

import Accessibility
import BellasReefAPI
import BellasReefKit
import Charts
import OSLog
import SwiftUI
import UIKit

private let log = Logger(subsystem: "com.bellasreef.app", category: "history")

/// Charts live here (design brief §3). The Tank tab keeps a sparkline; this is
/// the tab that answers "what has it been doing".
///
/// All five §7.1 states are distinct: loading, empty (the store has nothing for
/// this window), populated, error, and refreshing via pull-to-refresh.
struct HistoryTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var history: HistoryModel?

    /// D7 export. `exporting` gates the toolbar, `exportFile` drives the share
    /// sheet, `written` is the temporary file to delete once the sheet closes,
    /// and `exportError` is the one sentence the operator sees.
    @State private var exporting = false
    @State private var exportFile: ExportPayload?
    @State private var written: URL?
    @State private var exportError: String?

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
            // Inline titles blurred over content that scrolled under them (UX
            // review B2). The soft edge effect is the system's answer.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if exporting {
                        ProgressView()
                    } else if let history {
                        ExportMenu(devices: exportableDevices, name: deviceName) { device, format in
                            export(deviceId: device, format: format, range: history.range)
                        }
                    }
                }
            }
            // A `ShareLink` cannot be used here: it is a Button, so it can
            // only be tapped, and there is nothing to share until the export
            // has been fetched and written. Rendering one after the fact
            // would cost the operator a second tap on a control that appeared
            // out of nowhere. `UIActivityViewController` in a sheet is the
            // presentation the system offers for "share this, now", and it is
            // the same sheet `ShareLink` puts up.
            .sheet(item: $exportFile, onDismiss: discardExportFile) { payload in
                ShareSheet(url: payload.url)
            }
        }
        .task {
            // Runs on every appearance, not only on creation: SwiftUI cancels
            // this task when the tab is switched away from, and a cancelled
            // load now leaves `state` untouched (HistoryModel.load()) rather
            // than stamping a raw-dump failure — so the next visit re-runs
            // this and self-heals instead of showing a permanent error for a
            // load the app itself cancelled.
            //
            // `refresh()`, not `load()`: this — along with `.refreshable`,
            // the retry button and the `scenePhase` handler below — used to
            // call `load()` directly in its own untracked `Task`, so none of
            // the four could ever cancel another. A pull-to-refresh at 1H
            // racing a range flip to 7D could publish stale 1H data over the
            // 7D result. Every entry point now goes through `HistoryModel`'s
            // single tracked `loadTask` (`reload()`/`refresh()`), which is
            // also why `load()` itself is no longer reachable from here.
            if history == nil, let client = model.client, let catalog = model.catalog {
                history = HistoryModel(client: client, catalog: catalog)
            }
            await history?.refresh()
            // The export menu lists the registry, not the traces on screen —
            // see `exportableDevices` — and this tab never loaded the
            // registry before. Second, so the charts are not held up behind
            // it. Idempotent, and the Tank tab has usually already done it.
            await model.catalog?.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            // REST data does not push; returning to the app is when the
            // operator expects it to be current.
            if phase == .active { history?.reload() }
        }
    }

    @ViewBuilder
    private func content(_ history: HistoryModel) -> some View {
        @Bindable var history = history

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RangePicker(selection: $history.range)

                // An export that failed must not take the charts down with
                // it: this is a banner above them, not a replacement for
                // them, and the sentence in it comes from `HumanError`.
                if let exportError {
                    ExportFailure(why: exportError) { self.exportError = nil }
                }

                switch history.state {
                case .idle, .loading:
                    Loading()
                case let .failed(why):
                    Failure(why: why) { history.reload() }
                case .empty:
                    Empty(range: history.range)
                case .loaded:
                    // A mostly-empty window says why, once, above the charts
                    // (UX review B6). The axis stays the picked range — 7D
                    // means seven days — and this names where the record
                    // starts instead of clamping the plot to it.
                    if let window = history.window,
                       let caption = WindowCoverage.caption(
                           window: window, firstDataAt: history.firstDataAt
                       ) {
                        Text(caption)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(history.traces) { trace in
                        TraceChart(trace: trace, history: history)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await history.refresh() }
    }

    // MARK: Export (D7)

    /// The registry, not the traces on screen.
    ///
    /// A trace only exists for a device that recorded something inside the
    /// selected window, and the reason to export is often that the chart is
    /// not enough — a device that has been quiet all hour is exactly the one
    /// worth pulling a week of. Unadopted rows are left out: they belong to
    /// nobody yet, and the hub has no telemetry under them.
    private var exportableDevices: [Components.Schemas.DeviceView] {
        (model.catalog?.devices ?? [])
            .filter(\.adopted)
            .sorted { deviceName($0.deviceId) < deviceName($1.deviceId) }
    }

    private func deviceName(_ deviceId: String) -> String {
        model.catalog?.name(for: deviceId) ?? deviceId
    }

    /// Fetch, write, then present. The window is the picked range ending now,
    /// which is what the chart is showing; the file's own name records both
    /// bounds, so nothing about which window this was is left to memory.
    private func export(deviceId: String, format: ExportFormat, range: HistoryRange) {
        guard let client = model.client else { return }
        exporting = true
        exportError = nil
        Task {
            defer { exporting = false }
            let end = Date()
            let start = end.addingTimeInterval(-range.duration)
            do {
                let file = try await client.exportHistory(
                    deviceId: deviceId, from: start, to: end, format: format
                )
                discardExportFile()
                let url = FileManager.default.temporaryDirectory
                    .appending(path: file.suggestedFilename)
                try file.data.write(to: url, options: .atomic)
                written = url
                exportFile = ExportPayload(url: url)
            } catch {
                log.error("history export failed: \(String(describing: error))")
                exportError = HumanError.describe(error)
            }
        }
    }

    /// Deletes the temporary file once the share sheet has closed.
    ///
    /// The share sheet has finished with the URL by the time it dismisses —
    /// an activity that copies the file has already copied it. Leaving it
    /// would be harmless (the system reclaims its own temporary directory)
    /// but a tank's week of readings is not something to leave lying around
    /// unasked.
    private func discardExportFile() {
        guard let written else { return }
        try? FileManager.default.removeItem(at: written)
        self.written = nil
    }
}

/// The file, waiting for the share sheet. `URL` is not `Identifiable`, and
/// `.sheet(item:)` wants something that is.
struct ExportPayload: Identifiable {
    let id = UUID()
    let url: URL
}

/// Device, then format. Two levels because the export is per device and the
/// hub has more than one: a flat list of "Export <name> as CSV" grows as
/// devices times formats.
struct ExportMenu: View {
    let devices: [Components.Schemas.DeviceView]
    let name: (String) -> String
    let export: (String, ExportFormat) -> Void

    var body: some View {
        Menu {
            ForEach(devices, id: \.deviceId) { device in
                Menu(name(device.deviceId)) {
                    ForEach(ExportFormat.allCases) { format in
                        Button("Export \(format.label)") { export(device.deviceId, format) }
                    }
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        // Nothing adopted means nothing to export. Disabled rather than
        // hidden, so the control does not appear and disappear as the
        // registry loads.
        .disabled(devices.isEmpty)
    }
}

/// An export that failed. Same vocabulary as `Failure` above, different
/// verb and a dismissal rather than a retry: the menu that started this is
/// still in the toolbar, so a second attempt is one tap away already.
struct ExportFailure: View {
    let why: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Could not export", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Theme.attention)
            Text(why)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `UIActivityViewController`, because this sheet is put up in code.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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

    /// Where the finger is, while it is down. `nil` is the chart at rest.
    @State private var scrubbedAt: Date?

    /// The bucket under the finger, or `nil` over a gap (UX review B4).
    /// Decided in the kit, where it has tests; this only asks.
    private var scrubbedBucket: Components.Schemas.HistoryBucket? {
        guard let scrubbedAt, let step = history.bucketStep else { return nil }
        return HistoryScrub.bucket(at: scrubbedAt, in: trace.segments, step: step)
    }

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
                    // A segment of one bucket has no line to draw — a
                    // LineMark with one point renders nothing, and neither
                    // does the AreaMark — so a lone reading vanished (H2,
                    // 2026-08-18: today's hold missing from 24H and 7D while
                    // VictoriaMetrics had it). One dot, with its envelope as a
                    // short bar, says "this happened, once, here".
                    if segment.buckets.count == 1, let only = segment.buckets.first {
                        RuleMark(
                            x: .value("t", only.at),
                            yStart: .value("low", display(only.minimum)),
                            yEnd: .value("high", display(only.maximum))
                        )
                        .foregroundStyle(Theme.accent.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        PointMark(
                            x: .value("t", only.at),
                            y: .value("avg", display(only.average))
                        )
                        .foregroundStyle(Theme.accent)
                        .symbolSize(28)
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

                // The scrub crosshair (UX review B4). The rule follows the
                // finger; the dot marks the bucket it resolves to. Over a gap
                // there is no dot and the readout says so — snapping to the
                // nearest edge would put a number on time nothing was
                // recorded for, and the torn line already refused to.
                if let scrubbedAt {
                    RuleMark(x: .value("scrub", scrubbedAt))
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(
                            position: .top, spacing: 0,
                            // Kept inside the plot on both axes: the chart is
                            // 180pt tall with a header directly above it, and
                            // a readout that escaped upward would sit on the
                            // device name.
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))
                        ) {
                            ScrubReadout(
                                at: scrubbedBucket?.at ?? scrubbedAt,
                                bucket: scrubbedBucket,
                                range: history.range,
                                unit: axisLabel,
                                display: display
                            )
                        }
                    if let bucket = scrubbedBucket {
                        PointMark(
                            x: .value("t", bucket.at),
                            y: .value("avg", display(bucket.average))
                        )
                        .foregroundStyle(Theme.accent)
                        .symbolSize(48)
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
            // A drag across the plot scrubs; lifting the finger clears it.
            //
            // A plain `DragGesture` at its default 10pt threshold, not
            // `minimumDistance: 0`: this chart lives in a vertical
            // ScrollView, and a drag that claims the touch on contact would
            // either steal every scroll that starts on a chart or be
            // cancelled mid-scrub without `onEnded` ever firing, leaving the
            // crosshair stuck. At 10pt the scroll view takes a vertical
            // pull before this begins, and once this has begun a horizontal
            // move it keeps it.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { drag in
                                    guard let plot = proxy.plotFrame,
                                          let window = history.window else { return }
                                    let x = drag.location.x - geometry[plot].origin.x
                                    guard let at = proxy.value(atX: x, as: Date.self) else { return }
                                    // Clamped to the picked range: a finger
                                    // dragged past the plot edge must not
                                    // put the rule outside the window the
                                    // axis promised.
                                    scrubbedAt = min(max(at, window.lowerBound), window.upperBound)
                                }
                                .onEnded { _ in scrubbedAt = nil }
                        )
                }
            }
            .accessibilityLabel(Self.spoken(trace: trace, history: history))
            .accessibilityChartDescriptor(
                AudioGraph(
                    trace: trace,
                    window: history.window,
                    range: history.range,
                    unit: unit,
                    yDomain: yDomain
                )
            )

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
        let phrases = EpisodeSummary.phrases(for: history.bands(for: trace.deviceId))
        let floor = history.gapFloor.map(Self.resolution)

        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 12) {
            // Per class, tinted like the band it counts (UX review A2): a
            // silence is violet on the chart and violet here; a threshold
            // excursion is amber in both places.
            ForEach(phrases, id: \.text) { phrase in
                Label(
                    phrase.text,
                    systemImage: phrase.alertClass == .silence
                        ? "antenna.radiowaves.left.and.right.slash"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(phrase.alertClass == .silence ? Theme.silence : Theme.attention)
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
        // The pale band was the one unexplained mark on the chart (UX review
        // B5). One line, beside the gap disclosure so the two explanations of
        // what the plot does and does not show sit together.
        Text("The shaded band is each interval's low to high; the line is its average.")
            .foregroundStyle(Theme.tertiaryText)
        }
        .font(Theme.caption)
    }
}


/// What the crosshair is pointing at: the bucket's time, its average, and
/// its low–high; or the plain fact that nothing was recorded there.
struct ScrubReadout: View {
    let at: Date
    let bucket: Components.Schemas.HistoryBucket?
    let range: HistoryRange
    let unit: String
    let display: (Double) -> Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(at, format: range.readoutFormat)
                .foregroundStyle(Theme.secondaryText)
            if let bucket {
                // Average first and heaviest — it is the line the finger is
                // on. The envelope follows in the same breath so a spike the
                // line averaged away is still named.
                HStack(spacing: 6) {
                    Text(HistoryScrub.label(display(bucket.average), unit: unit))
                        .foregroundStyle(Theme.primaryText)
                        .fontWeight(.semibold)
                    Text(HistoryScrub.label(display(bucket.minimum), unit: unit)
                         + "–" + HistoryScrub.label(display(bucket.maximum), unit: unit))
                        .foregroundStyle(Theme.tertiaryText)
                }
            } else {
                Text("Nothing recorded")
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .font(Theme.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.surfaceRaised.opacity(0.92), in: .rect(cornerRadius: 8))
        // The chart's own accessibility label and descriptor speak for it;
        // a transient readout under a finger is not a second element.
        .accessibilityHidden(true)
    }
}

/// The chart, for VoiceOver's audio graph (UX review B4).
///
/// Its own struct rather than a conformance on `TraceChart`:
/// `makeChartDescriptor()` is nonisolated and `TraceChart` is not, so this
/// carries plain values captured at render time and touches nothing on the
/// main actor when the graph is played.
struct AudioGraph: AXChartDescriptorRepresentable {
    let trace: HistoryTrace
    let window: ClosedRange<Date>?
    let range: HistoryRange
    let unit: TemperatureUnitPreference
    let yDomain: ClosedRange<Double>

    /// The same conversion the plot uses, so the graph and the picture agree.
    private func display(_ value: Double) -> Double {
        guard trace.isTemperature else { return value * 100 }
        return TemperatureDisplay.measurement(celsius: value, as: unit).value
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        // The x axis is the picked range, same as the plot; a graph whose
        // width was the data's extent would redefine "7 days" the same way
        // an inferred domain did.
        let lower = window?.lowerBound ?? trace.segments.first?.buckets.first?.at ?? Date()
        let upper = window?.upperBound ?? trace.segments.last?.buckets.last?.at ?? lower
        let format = range.readoutFormat
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: lower.timeIntervalSince1970...max(upper.timeIntervalSince1970, lower.timeIntervalSince1970 + 1),
            gridlinePositions: []
        ) { Date(timeIntervalSince1970: $0).formatted(format) }

        let symbol = trace.isTemperature ? TemperatureDisplay.symbol(for: unit) : "%"
        let yAxis = AXNumericDataAxisDescriptor(
            title: trace.isTemperature ? "Temperature" : "Output",
            range: yDomain,
            gridlinePositions: []
        ) { HistoryScrub.label($0, unit: symbol) }

        // One series per segment, not one for the trace: the audio graph
        // sweeps a continuous series from point to point, and a single one
        // would sound a tone straight across a gap the line refuses to draw.
        // Named by part only when there is more than one, so an unbroken
        // record is just "Average".
        let parts = trace.segments.count
        let series = trace.segments.enumerated().map { index, segment in
            AXDataSeriesDescriptor(
                name: parts > 1 ? "Average, part \(index + 1) of \(parts)" : "Average",
                isContinuous: segment.buckets.count > 1,
                dataPoints: segment.buckets.map { bucket in
                    AXDataPoint(x: bucket.at.timeIntervalSince1970, y: display(bucket.average))
                }
            )
        }

        return AXChartDescriptor(
            title: "\(trace.name) history",
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series
        )
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

    /// The scrub readout's time: the axis format, plus enough to tell one
    /// bucket from the next. 7D adds a clock to the weekday; 1H buckets are
    /// 30 s wide, so a minute alone would name two of them the same.
    var readoutFormat: Date.FormatStyle {
        switch self {
        case .week: .dateTime.weekday(.abbreviated).hour().minute()
        case .hour: .dateTime.hour().minute().second()
        default: .dateTime.hour().minute()
        }
    }

}
