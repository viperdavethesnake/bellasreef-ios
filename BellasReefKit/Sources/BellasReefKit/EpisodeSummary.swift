// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation

/// The one-line summary under a history chart, per episode class.
///
/// UX review A2 (2026-08-17): the summary said "1 alert episode" in the
/// attention tint for a band the chart drew violet, because it counted bands
/// and dropped the class. "1 gap in reporting" and "1 threshold excursion" are
/// different events for the reader, and the schema went to the trouble of
/// keeping them apart — the summary keeps them apart too. Silence first, so
/// "the hub was not hearing the probe" reads before "the tank was out of
/// range": the first can make the second unknowable.
public enum EpisodeSummary {
    public struct Phrase: Equatable, Sendable {
        public let alertClass: HistoryEpisodeClass
        public let text: String
        public init(alertClass: HistoryEpisodeClass, text: String) {
            self.alertClass = alertClass
            self.text = text
        }
    }

    public static func phrases(for bands: [AlertBand]) -> [Phrase] {
        var out: [Phrase] = []
        let silences = bands.filter { $0.alertClass == .silence }.count
        if silences > 0 {
            out.append(Phrase(alertClass: .silence,
                              text: silences == 1 ? "1 gap in reporting" : "\(silences) gaps in reporting"))
        }
        let excursions = bands.filter { $0.alertClass == .threshold }.count
        if excursions > 0 {
            out.append(Phrase(alertClass: .threshold,
                              text: excursions == 1 ? "1 threshold excursion" : "\(excursions) threshold excursions"))
        }
        return out
    }
}
