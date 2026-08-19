// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Foundation
import Testing

@testable import BellasReefKit

/// UX review A2: the History summary said "1 alert episode" in the attention
/// tint for a silence band the chart itself drew violet. The schema kept the
/// class; the summary threw it away. These pin the phrasing per class.
@Suite("Episode summary by class")
struct EpisodeSummaryTests {
    private func band(_ cls: HistoryEpisodeClass) -> AlertBand {
        AlertBand(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60),
                  alertClass: cls, bound: nil, isOngoing: false)
    }

    @Test("no bands, no phrases")
    func none() {
        #expect(EpisodeSummary.phrases(for: []).isEmpty)
    }

    @Test("a silence is a gap in reporting, not an excursion")
    func silence() {
        let phrases = EpisodeSummary.phrases(for: [band(.silence)])
        #expect(phrases == [EpisodeSummary.Phrase(alertClass: .silence, text: "1 gap in reporting")])
    }

    @Test("a threshold band is an excursion; plurals per class")
    func thresholdAndPlural() {
        let phrases = EpisodeSummary.phrases(for: [band(.threshold), band(.threshold), band(.silence)])
        #expect(phrases == [
            EpisodeSummary.Phrase(alertClass: .silence, text: "1 gap in reporting"),
            EpisodeSummary.Phrase(alertClass: .threshold, text: "2 threshold excursions"),
        ])
    }
}
