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
        // Not "": every fact the hub announces for a PCA channel is
        // board-wide and lives in the header, but the row still carries the
        // same identity Lighting and Devices print (ruled 2026-08-25) — see
        // `pcaRowSpeaksTheDeviceVoice`.
        #expect(g.rowDetail(for: g.channels[0]) == "pca9685 · ch 1")
    }

    @Test("a PCA9685 row carries the identity Lighting prints: pca9685 · ch n")
    func pcaRowSpeaksTheDeviceVoice() {
        // The RP1 rows earn their detail line from a real per-channel fact
        // (the gpio mux); the PCA9685 announces only board-wide facts, which
        // the header absorbs, and its rows read bare — one voice in Hardware,
        // another (`pca9685 · ch 0`) everywhere else. Ruled 2026-08-25, at
        // the bench, second iteration ("LEDn" rejected — the datasheet's
        // name, not the operator's; this is a PWM channel): every PCA row
        // carries the full identity exactly as the Lighting picker and the
        // Devices subtitle already say it.
        let free = [
            cap(.pca9685, "0", ["address": "0x40", "bus": 1]),
            cap(.pca9685, "15", ["address": "0x40", "bus": 1]),
        ]
        let g = ChannelGroups.group(free)[0]
        #expect(g.rowDetail(for: g.channels[0]) == "pca9685 · ch 0")
        #expect(g.rowDetail(for: g.channels[1]) == "pca9685 · ch 15")
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

    /// Hand-built ChipStateView rows — same idiom as `cap`: generated inits
    /// take alphabetically ordered labels (announcedAt, facts, initialised,
    /// initialisedAt, instance, source).
    private func chip(
        _ source: String, _ facts: [String: Components.Schemas.ChipStateView.FactsPayload.AdditionalPropertiesPayload],
        initialised: Bool = true
    ) -> Components.Schemas.ChipStateView {
        .init(
            announcedAt: Date(timeIntervalSince1970: 1_787_000_000),
            facts: .init(additionalProperties: facts),
            initialised: initialised,
            initialisedAt: Date(timeIntervalSince1970: 1_787_000_000),
            instance: "test-instance",
            source: source
        )
    }

    @Test("chip state attaches to its board's group by source")
    func chipStateAttaches() {
        let groups = ChannelGroups.group(
            [cap(.pca9685, "0", ["address": "0x40"])],
            chipStates: [chip("pca9685", ["channels": .init(value2: 16)])]
        )
        #expect(groups.count == 1)
        #expect(groups[0].state != nil)
    }

    @Test("PCA9685 state line: initialised · frequency · INVRT · channels")
    func pcaStateLine() {
        let group = ChannelGroups.group(
            [cap(.pca9685, "0", [:])],
            chipStates: [chip("pca9685", [
                "frequency_hz": .init(value3: 502.7),
                "invrt": .init(value4: false),
                "channels": .init(value2: 16),
            ])]
        )[0]
        #expect(group.stateLine == "initialised · 502.7 Hz · INVRT off · 16 channels")
    }

    @Test("Pi PWM state line: frequency · polarity · channels, whole hertz without decimals")
    func piPwmStateLine() {
        let group = ChannelGroups.group(
            [cap(.piPwm, "0", [:])],
            chipStates: [chip("pi-pwm", [
                "frequency_hz": .init(value3: 500.0),
                "polarity": .init(value1: "normal"),
                "channels": .init(value2: 4),
            ])]
        )[0]
        #expect(group.stateLine == "500 Hz · normal · 4 channels")
    }

    @Test("1-Wire state line pluralises probes")
    func w1StateLine() {
        let one = ChannelGroups.group(
            [cap(.w1Bus, "28-000000bfe244", [:])],
            chipStates: [chip("w1-bus", ["probes": .init(value2: 1)])]
        )[0]
        #expect(one.stateLine == "1 probe")
        let three = ChannelGroups.group(
            [cap(.w1Bus, "28-000000bfe244", [:])],
            chipStates: [chip("w1-bus", ["probes": .init(value2: 3)])]
        )[0]
        #expect(three.stateLine == "3 probes")
    }

    @Test("chip state unknown (no chipStates argument) renders no second line")
    func noStateLineUnknown() {
        let group = ChannelGroups.group([cap(.pca9685, "0", [:])])[0]
        #expect(group.stateLine == nil)
    }

    @Test("chip state known-empty for this board says why, in the spec's words")
    func noStateLineKnownEmpty() {
        let group = ChannelGroups.group([cap(.pca9685, "0", [:])], chipStates: [])[0]
        #expect(group.stateLine == "not initialised — no channel adopted")
    }
}
