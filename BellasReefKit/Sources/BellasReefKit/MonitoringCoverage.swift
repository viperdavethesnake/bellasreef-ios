// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC

/// What "All clear" is standing on.
///
/// Silence alerting runs on every probe unconditionally; threshold alerting
/// only on a probe with a band. Both are "clear" when nothing has fired, but
/// they are different safety postures, and the status line showed them
/// identically (UX review A1). This is the note the line appends when the
/// answer is "clear, but not everything you might think is being watched".
///
/// A note, not a tone change: nothing is wrong, something is absent — teal
/// stays teal. The sensor sheet is where the band gets set.
public enum MonitoringCoverage {
    /// `hasBand` answers whether the probe has both bounds configured.
    public static func note(sensorIds: [String], hasBand: (String) -> Bool) -> String? {
        guard !sensorIds.isEmpty else { return nil }
        let unbanded = sensorIds.filter { !hasBand($0) }.count
        if unbanded == 0 { return nil }
        if unbanded == sensorIds.count { return "no thresholds set" }
        return "\(unbanded) of \(sensorIds.count) sensors without thresholds"
    }
}
