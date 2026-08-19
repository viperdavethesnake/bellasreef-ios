// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import BellasReefAPI
import Foundation

/// What a finger dragged across a History chart is pointing at.
///
/// UX review B4: the charts had no scrub readout. The gesture and the
/// crosshair are the view's; which bucket is under the finger is decided
/// here, where it can be tested without a chart. Two rules, both from the
/// chart's own design:
///
/// - Nearest by time, not "the bucket whose interval contains the finger":
///   `at` is a bucket's start and the samples are spread through it, so a
///   finger halfway between two starts is closer to the second than the
///   interval arithmetic would say.
/// - Never farther than one step. Buckets inside a segment sit at most 1.5
///   steps apart (`HistoryModel.tolerance`), so a finger over drawn line is
///   always within 0.75 of one. Past that it is over a gap or off the end of
///   the record, and the honest answer is no bucket — snapping across a hole
///   to the nearest edge would put a number on time the hub recorded nothing
///   for, which is exactly what the torn line exists to refuse.
public enum HistoryScrub {
    public static func bucket(
        at date: Date, in segments: [HistorySegment], step: TimeInterval
    ) -> Components.Schemas.HistoryBucket? {
        var best: (bucket: Components.Schemas.HistoryBucket, distance: TimeInterval)?
        for bucket in segments.lazy.flatMap(\.buckets) {
            let distance = abs(bucket.at.timeIntervalSince(date))
            if best.map({ distance < $0.distance }) ?? true {
                best = (bucket, distance)
            }
        }
        guard let best, best.distance <= step else { return nil }
        return best.bucket
    }

    /// One number for the readout, in the unit the axis already shows.
    ///
    /// Takes the value as displayed — the view has already converted
    /// Celsius to the operator's unit and duty to percent — and only decides
    /// precision: one decimal for temperature, the same reason as
    /// `TemperatureDisplay.value`; whole percent for duty, because a channel
    /// does not hold a duty to a tenth of a percent and the axis does not
    /// pretend it does.
    public static func label(_ shown: Double, unit: String, locale: Locale = .current) -> String {
        let places = unit == "%" ? 0 : 1
        return shown.formatted(.number.precision(.fractionLength(places)).locale(locale)) + unit
    }
}
