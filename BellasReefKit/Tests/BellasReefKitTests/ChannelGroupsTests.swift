// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import BellasReefAPI
import Foundation
import OpenAPIRuntime
import Testing

@testable import BellasReefKit

/// UX review C1/C2: sixteen `pca9685 · channel N · address 0x40 · bus 1`
/// rows in one flat list. Hardware is board → channel: one section per
/// source, headed by what every channel in it shares, rows carrying only
/// what differs.
@Suite("Available channels grouped by board")
struct ChannelGroupsTests {
    private func cap(_ source: Components.Schemas.CapabilityView.SourcePayload, _ channel: String,
                     _ detail: [String: (any Sendable)?]) -> Components.Schemas.CapabilityView {
        Components.Schemas.CapabilityView(
            announcedAt: Date(timeIntervalSince1970: 0), boundTo: nil, channel: channel,
            detail: .init(additionalProperties: try! OpenAPIObjectContainer(unvalidatedValue: detail)),
            source: source)
    }

    @Test("one group per source, in a stable order, pi-pwm before pca9685")
    func groups() {
        let free = [
            cap(.pca9685, "3", ["address": "0x40", "bus": 1]),
            cap(.piPwm, "2", ["chip": "pwmchip0", "gpio": 18]),
            cap(.pca9685, "1", ["address": "0x40", "bus": 1]),
        ]
        let groups = ChannelGroups.group(free)
        #expect(groups.map(\.source) == [.piPwm, .pca9685])
        #expect(groups[1].channels.map(\.channel) == ["1", "3"])
    }

    @Test("the header carries what every channel shares; rows keep what differs")
    func sharedDetail() {
        let free = [
            cap(.pca9685, "1", ["address": "0x40", "bus": 1]),
            cap(.pca9685, "2", ["address": "0x40", "bus": 1]),
        ]
        let g = ChannelGroups.group(free)[0]
        #expect(g.title == "PCA9685 board")
        #expect(g.subtitle == "address 0x40 · bus 1")
        #expect(g.rowDetail(for: g.channels[0]) == "")
    }

    @Test("a per-channel value stays on the row")
    func perRow() {
        let free = [
            cap(.piPwm, "1", ["chip": "pwmchip0", "gpio": 12]),
            cap(.piPwm, "2", ["chip": "pwmchip0", "gpio": 13]),
        ]
        let g = ChannelGroups.group(free)[0]
        #expect(g.title == "Pi PWM")
        #expect(g.subtitle == "chip pwmchip0")
        #expect(g.rowDetail(for: g.channels[1]) == "gpio 13")
    }
}
