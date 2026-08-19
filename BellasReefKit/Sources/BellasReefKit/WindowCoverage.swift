// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation

/// Why most of a chart is empty, when it is.
///
/// UX review B6: 7D with a day of data is 85 % blank axis. The reviewer offered
/// clamping the domain to the data; that would make "7D" stop meaning seven
/// days, and the picked range is deliberately the axis (`HistoryView`). So the
/// axis stays honest and this caption says where the record begins — only when
/// the data covers under half the window, because a chart that is mostly full
/// needs no excuse.
public enum WindowCoverage {
    public static func caption(
        window: ClosedRange<Date>, firstDataAt: Date?, timeZone: TimeZone = .current
    ) -> String? {
        guard let firstDataAt else { return nil }
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let covered = window.upperBound.timeIntervalSince(max(firstDataAt, window.lowerBound))
        guard span > 0, covered / span < 0.5 else { return nil }

        let inDays = span >= 2 * 86_400
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = inDays ? "d MMM" : "HH:mm"
        let unit = inDays ? 86_400.0 : 3600.0
        let have = max(1, Int((covered / unit).rounded()))
        let shown = Int((span / unit).rounded())
        let word = inDays ? "day" : "hour"
        return "The record starts \(f.string(from: firstDataAt)) — about \(have) \(word)\(have == 1 ? "" : "s") of the \(shown) shown."
    }
}
