// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.bellasreef.app", category: "history")

/// How far back the History tab is looking.
public enum HistoryRange: String, CaseIterable, Sendable, Identifiable {
    case hour, sixHours, day, week

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hour: "1H"
        case .sixHours: "6H"
        case .day: "24H"
        case .week: "7D"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .hour: 3600
        case .sixHours: 6 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        }
    }

    /// Buckets requested for this range.
    ///
    /// Roughly one per two points of chart width — asking for more would only
    /// move samples across the network to be averaged again by the renderer.
    public var buckets: Int {
        switch self {
        case .hour: 120
        case .sixHours: 180
        case .day: 240
        case .week: 336
        }
    }
}

/// One contiguous run of buckets, with no gap inside it.
///
/// The chart draws a separate line per segment. `bellasreef_actuator_level`
/// comes from a last-value-retained stream, so duty genuinely has holes when
/// the telemetry writer was down; a single line across the whole series would
/// draw straight through them and assert a continuity nothing measured.
public struct HistorySegment: Identifiable, Sendable {
    public let id: Int
    public let buckets: [Components.Schemas.HistoryBucket]
}

/// A series prepared for drawing.
public struct HistoryTrace: Identifiable, Sendable {
    public let id: String
    public let deviceId: String
    public let name: String
    public let unit: String
    public let isTemperature: Bool
    public let segments: [HistorySegment]

    public var isEmpty: Bool { segments.allSatisfy(\.buckets.isEmpty) }
}

@MainActor
@Observable
public final class HistoryModel {

    /// §7.1, explicitly. "No data" and "could not load" are different answers
    /// and a chart that shows an empty grid for both is lying about one of them.
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var traces: [HistoryTrace] = []
    public private(set) var episodes: [Components.Schemas.HistoryEpisode] = []
    /// The visible window, and the chart's x domain verbatim.
    ///
    /// The domain IS the selected range. Letting Charts infer it from returned
    /// data meant 7D quietly redrew itself as "the last four hours, full width"
    /// whenever the hub had been down, which is how a gap stops looking like a
    /// gap.
    ///
    /// KNOWN CONSEQUENCE, ruled won't-fix: Charts does not lay out an axis label
    /// for a mark that sits exactly on the domain's upper bound, so the trailing
    /// label is absent at every range. It is not a clipping or collision
    /// problem — trailing padding, `.greedy` collision resolution and insetting
    /// the plot were all tried and none reach it, because the label is never
    /// laid out at all. The only remaining fix is widening the domain past the
    /// selected range, which would trade a correctness property for a cosmetic
    /// one. The domain stays honest and the label stays missing.
    public private(set) var window: ClosedRange<Date>?

    /// The shortest outage this range could possibly have noticed.
    ///
    /// Gaps are found by looking for a missing bucket, so nothing shorter than
    /// a bucket is visible at all — the samples either side of a 60s outage
    /// land in the same 2-minute bucket and it simply is not there to see. That
    /// is why the same period honestly reports one gap at 1H and none at 6H,
    /// and why the footnote states this number instead of letting the two
    /// answers look like a contradiction.
    ///
    /// The real fix is finer than wording: the hub would have to report the
    /// sample count per bucket, so a bucket holding fewer samples than its
    /// cadence predicts could be flagged as internally holed. That is a
    /// contract change and it is not this one.
    public private(set) var gapFloor: TimeInterval?

    public var range: HistoryRange = .day {
        didSet { reload() }
    }

    private let client: HubClient
    private let catalog: DeviceCatalog

    /// The in-flight load, if any. Lets a new request supersede an old one
    /// instead of racing it.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init(client: HubClient, catalog: DeviceCatalog) {
        self.client = client
        self.catalog = catalog
    }

    /// Cancels whatever load is in progress and starts a tracked replacement.
    ///
    /// The one place that touches `loadTask`, behind both `reload()` and
    /// `refresh()`. Every view entry point — range change, retry, returning
    /// to the foreground, pull-to-refresh, the initial `.task` — goes
    /// through one of those two, so no matter which fires last, it is the
    /// one whose result survives; an in-flight sibling gets cancelled here
    /// before it ever gets the chance to publish.
    ///
    /// Finding, 2026-08-15 (second pass): `range.didSet` alone spawning
    /// `Task { await load() }` was not enough — `.refreshable`, the retry
    /// button and the `scenePhase` handler each called `load()` in their own
    /// untracked `Task`, so a pull-to-refresh at 1H racing a flip to 7D could
    /// still publish stale 1H data over the 7D result: `checkCancellation()`
    /// never fires for a task nothing ever cancels. `load()` is no longer
    /// `public` for exactly this reason — the compiler is what now enforces
    /// that every caller goes through the tracked path.
    private func supersede() -> Task<Void, Never> {
        loadTask?.cancel()
        let task = Task { await load() }
        loadTask = task
        return task
    }

    /// Fire-and-forget single-flight entry point: range changes, retry, and
    /// returning to the foreground don't own a spinner to wait on.
    public func reload() {
        _ = supersede()
    }

    /// Awaitable single-flight entry point: pull-to-refresh's `.refreshable`
    /// needs to know when the load actually finished (so its spinner stops),
    /// and the initial `.task` awaits this the same way. If a `reload()`
    /// races in and supersedes it, this still returns cleanly — `load()`'s
    /// own cancellation handling makes that a clean return, not a hang.
    public func refresh() async {
        await supersede().value
    }

    /// Not `public`: every caller reaches this through `reload()`/`refresh()`
    /// so the single-flight guarantee above cannot be bypassed by a new view
    /// entry point calling `load()` directly, the way four of them once did.
    /// Kit tests call this directly to exercise cancellation-transparency
    /// and error formatting in isolation, without the timing a full
    /// `reload()`/`refresh()` race would need — `@testable import` reaches
    /// `internal`, which is what makes that legitimate rather than a leak.
    func load() async {
        if traces.isEmpty { state = .loading }
        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        window = start...end

        do {
            let view = try await client.history(from: start, to: end, buckets: range.buckets)
            // A load cancelled between the request landing and here must not
            // publish results for a range nobody is looking at anymore —
            // `client.history` does not itself check cancellation.
            try Task.checkCancellation()
            // `bucket_s` is what the hub actually used, not what was asked for.
            // Segmenting on the requested size would tear a series apart the
            // moment the cap changed the step.
            let step = TimeInterval(view.bucketS ?? 60)
            gapFloor = Self.tolerance(step: step)
            traces = view.series.map { series in
                HistoryTrace(
                    id: "\(series.deviceId)/\(series.metric)",
                    deviceId: series.deviceId,
                    name: catalog.name(for: series.deviceId),
                    unit: series.unit,
                    isTemperature: series.unit == "degC",
                    segments: Self.segment(series.buckets, step: step)
                )
            }
            episodes = view.episodes
            state = traces.contains { !$0.isEmpty } ? .loaded : .empty
        } catch {
            // Our own cancellation is not news — a tab switch cancelling
            // this `.task`, or `reload()` superseding it — so it leaves
            // `state` exactly as it was and the next load gets a clean run.
            // Finding, 2026-08-15: this used to render as a permanent
            // failure screen carrying the raw transport dump, for a request
            // the app itself cancelled while the server was healthy.
            guard !HumanError.isCancellation(error) else { return }
            log.error("history load failed: \(String(describing: error))")
            state = .failed(HumanError.describe(error))
        }
    }

    /// Split into runs, breaking wherever a bucket is missing.
    ///
    /// The hub omits empty buckets rather than zero-filling them, so a jump of
    /// more than one step means "nothing was recorded here". 1.5× rather than
    /// 1.0× because bucket boundaries and sample timing do not align exactly,
    /// and tearing the line on ordinary jitter would be its own kind of lie.
    static func segment(
        _ buckets: [Components.Schemas.HistoryBucket], step: TimeInterval
    ) -> [HistorySegment] {
        guard !buckets.isEmpty else { return [] }
        let tolerance = Self.tolerance(step: step)

        var segments: [HistorySegment] = []
        var current: [Components.Schemas.HistoryBucket] = [buckets[0]]
        for bucket in buckets.dropFirst() {
            let previous = current[current.count - 1].at
            if bucket.at.timeIntervalSince(previous) > tolerance {
                segments.append(HistorySegment(id: segments.count, buckets: current))
                current = []
            }
            current.append(bucket)
        }
        segments.append(HistorySegment(id: segments.count, buckets: current))
        return segments
    }

    /// How large a hole has to be before it counts as one.
    ///
    /// 1.5x rather than 1.0x because bucket boundaries and sample timing do not
    /// align exactly, and tearing the line on ordinary jitter would be its own
    /// kind of lie.
    static func tolerance(step: TimeInterval) -> TimeInterval {
        max(step * 1.5, 1)
    }

    /// Episodes for one device, clamped to the visible window.
    ///
    /// An open episode has no `cleared_at` — the hub leaves it open rather than
    /// inventing a clear time — so the band runs to the edge of the window,
    /// which is the honest rendering of "still happening". `isOngoing` carries
    /// that fact to the renderer rather than leaving it to infer one from a band
    /// that reaches the right edge, which is also what a breach clearing at
    /// exactly now looks like.
    ///
    /// Merged per class before returning. Overlapping rectangles composite their
    /// opacity, so a probe with an open min breach *and* an open silence would
    /// otherwise stack into a block dark enough to hide the trace underneath.
    /// Merging caps it at one layer per class, which is what makes the opacity
    /// ceiling in the view a fact rather than a hope.
    public func bands(for deviceId: String) -> [AlertBand] {
        guard let window else { return [] }

        let mine = episodes.filter { $0.deviceId == deviceId }
        var out: [AlertBand] = []

        for alertClass in [HistoryEpisodeClass.silence, .threshold] {
            let clipped: [AlertBand] = mine
                .filter { HistoryEpisodeClass(episode: $0) == alertClass }
                .map { episode in
                    // A silence band starts where the data stopped, not where the
                    // hub noticed. Those are six cadences apart, and starting at
                    // the later one would leave the gap it exists to explain
                    // conspicuously unmarked.
                    let began = episode.lastReadingAt ?? episode.raisedAt
                    return AlertBand(
                        start: max(began, window.lowerBound),
                        end: min(episode.clearedAt ?? window.upperBound, window.upperBound),
                        alertClass: alertClass,
                        bound: episode.bound.map { $0 == .max ? "max" : "min" },
                        isOngoing: episode.clearedAt == nil
                    )
                }
                .filter { $0.end > $0.start }
                .sorted { $0.start < $1.start }

            out.append(contentsOf: Self.merge(clipped))
        }
        return out
    }

    /// Union overlapping bands of one class into single spans.
    ///
    /// Ongoing-ness survives a merge if any member was ongoing: the union is
    /// still happening if any part of it is.
    static func merge(_ bands: [AlertBand]) -> [AlertBand] {
        guard var current = bands.first else { return [] }
        var merged: [AlertBand] = []

        for band in bands.dropFirst() {
            if band.start <= current.end {
                current = AlertBand(
                    start: current.start,
                    end: max(current.end, band.end),
                    alertClass: current.alertClass,
                    bound: current.bound == band.bound ? current.bound : nil,
                    isOngoing: current.isOngoing || band.isOngoing
                )
            } else {
                merged.append(current)
                current = band
            }
        }
        merged.append(current)
        return merged
    }

    /// The newest bucket that carries real data, across every series.
    ///
    /// An ongoing band is drawn solid only up to here. Past it the band is
    /// inference — we believe the condition continues because nothing has told
    /// us otherwise — and drawing inference at the same weight as record is how
    /// a chart starts lying politely.
    public var lastDataAt: Date? {
        traces.flatMap(\.segments).flatMap(\.buckets).map(\.at).max()
    }

    /// The oldest bucket that carries real data, across every series — where
    /// the record starts, for the sparse-window caption (UX review B6).
    public var firstDataAt: Date? {
        traces.flatMap(\.segments).flatMap(\.buckets).map(\.at).min()
    }
}

/// Which kind of episode a band is drawing.
public enum HistoryEpisodeClass: String, Sendable {
    case threshold, silence

    init(episode: Components.Schemas.HistoryEpisode) {
        self = episode.alertClass == .silence ? .silence : .threshold
    }
}

/// One alert band, ready to draw.
public struct AlertBand: Identifiable, Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let alertClass: HistoryEpisodeClass
    /// `nil` for a silence, and for a merged span that covered both bounds.
    public let bound: String?
    /// Still open at the hub. Distinct from "reaches the window edge", which a
    /// breach clearing right now also does.
    public let isOngoing: Bool

    public var id: String {
        "\(alertClass.rawValue)-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)"
    }

    /// Where the solid part of the band stops.
    ///
    /// A bounded episode is solid throughout: both ends are recorded fact. An
    /// ongoing one is only fact up to the last sample the hub actually has —
    /// past that, the band is an inference the fade is there to admit to.
    public func settledEnd(lastData: Date?) -> Date {
        guard isOngoing, let lastData else { return end }
        return min(max(lastData, start), end)
    }

    public init(
        start: Date, end: Date, alertClass: HistoryEpisodeClass, bound: String?, isOngoing: Bool
    ) {
        self.start = start
        self.end = end
        self.alertClass = alertClass
        self.bound = bound
        self.isOngoing = isOngoing
    }
}
