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
    public private(set) var window: ClosedRange<Date>?

    public var range: HistoryRange = .day {
        didSet { Task { await load() } }
    }

    private let client: HubClient
    private let catalog: DeviceCatalog

    public init(client: HubClient, catalog: DeviceCatalog) {
        self.client = client
        self.catalog = catalog
    }

    public func load() async {
        if traces.isEmpty { state = .loading }
        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        window = start...end

        do {
            let view = try await client.history(from: start, to: end, buckets: range.buckets)
            // `bucket_s` is what the hub actually used, not what was asked for.
            // Segmenting on the requested size would tear a series apart the
            // moment the cap changed the step.
            let step = TimeInterval(view.bucketS ?? 60)
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
            log.error("history load failed: \(String(describing: error))")
            state = .failed("\(error)")
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
        let tolerance = max(step * 1.5, 1)

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

    /// Episodes for one device, clamped to the visible window.
    ///
    /// An open episode has no `cleared_at` — the hub leaves it open rather than
    /// inventing a clear time — so the band runs to the edge of the window,
    /// which is the honest rendering of "still happening".
    public func bands(for deviceId: String) -> [(start: Date, end: Date, bound: String)] {
        guard let window else { return [] }
        return episodes
            .filter { $0.deviceId == deviceId }
            .map { episode in
                (
                    start: max(episode.raisedAt, window.lowerBound),
                    end: min(episode.clearedAt ?? window.upperBound, window.upperBound),
                    bound: episode.bound == .max ? "max" : "min"
                )
            }
            .filter { $0.end > $0.start }
    }
}
