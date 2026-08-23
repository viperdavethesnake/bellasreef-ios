// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import BellasReefAPI
import Foundation

/// Available channels, board by board.
///
/// UX review C1/C2: the System tab listed sixteen `pca9685 · channel N ·
/// address 0x40 · bus 1` rows in one scroll, the shared identity repeated on
/// every one. Hardware is board → channel: one group per source, headed by
/// what every channel in it shares, rows carrying only what differs. Bounded
/// at 16 + 4 rows for the hardware David has ruled is the boundary (E2), and
/// it will be the home of per-chip state when that reaches the wire.
public enum ChannelGroups {
    public struct Group: Identifiable, Sendable {
        public let source: Components.Schemas.CapabilityView.SourcePayload
        public let channels: [Components.Schemas.CapabilityView]
        /// Detail keys whose value is the same on every channel in the group.
        public let shared: [(String, String)]
        /// What this board's chip last said about itself, when anything on
        /// it has been adopted — `initialise()` only runs at adoption, so an
        /// untouched board legitimately has no row (spec 2026-08-19 §iOS).
        public let state: Components.Schemas.ChipStateView?

        public var id: String { source.rawValue }

        /// The board, in the words a person uses for it.
        public var title: String {
            switch source {
            case .piPwm: "Pi PWM"
            case .pca9685: "PCA9685 board"
            case .w1Bus: "1-Wire bus"
            }
        }

        /// What every channel here has in common — the address, the bus, the
        /// chip — said once, in the header.
        public var subtitle: String {
            shared.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        }

        /// What is particular to one channel — a GPIO, say. Empty when the
        /// header already said everything.
        public func rowDetail(for channel: Components.Schemas.CapabilityView) -> String {
            let sharedKeys = Set(shared.map(\.0))
            return flat(channel)
                .filter { !sharedKeys.contains($0.0) }
                .map { "\($0.0) \($0.1)" }
                .joined(separator: " · ")
        }

        /// The chip's own account, one line, in the spec's exact shapes:
        /// `initialised · 502.7 Hz · INVRT off · 16 channels` (PCA9685),
        /// `500 Hz · normal · 4 channels` (Pi PWM), `1 probe` (1-Wire).
        /// Facts a chip did not report are skipped, not rendered as blanks.
        public var stateLine: String {
            guard let state else { return "not initialised — no channel adopted" }
            var parts: [String] = []
            switch source {
            case .pca9685:
                parts.append(state.initialised ? "initialised" : "not initialised")
                if let hz = fact(double: "frequency_hz") { parts.append(Self.hertz(hz)) }
                if let invrt = fact(bool: "invrt") { parts.append(invrt ? "INVRT on" : "INVRT off") }
                if let n = fact(int: "channels") { parts.append("\(n) channels") }
            case .piPwm:
                if let hz = fact(double: "frequency_hz") { parts.append(Self.hertz(hz)) }
                if let polarity = fact(string: "polarity") { parts.append(polarity) }
                if let n = fact(int: "channels") { parts.append("\(n) channels") }
            case .w1Bus:
                if let n = fact(int: "probes") { parts.append(n == 1 ? "1 probe" : "\(n) probes") }
            }
            return parts.joined(separator: " · ")
        }

        /// 500.0 reads "500 Hz"; 502.7 reads "502.7 Hz" — a decimal is shown
        /// only when it carries information.
        private static func hertz(_ hz: Double) -> String {
            hz == hz.rounded() ? "\(Int(hz)) Hz" : String(format: "%.1f Hz", hz)
        }

        private func fact(string key: String) -> String? {
            state?.facts.additionalProperties[key]?.value1
        }
        private func fact(int key: String) -> Int? {
            state?.facts.additionalProperties[key]?.value2
        }
        private func fact(double key: String) -> Double? {
            guard let value = state?.facts.additionalProperties[key] else { return nil }
            return value.value3 ?? value.value2.map(Double.init)
        }
        private func fact(bool key: String) -> Bool? {
            state?.facts.additionalProperties[key]?.value4
        }
    }

    public static func group(
        _ channels: [Components.Schemas.CapabilityView],
        chipStates: [Components.Schemas.ChipStateView] = []
    ) -> [Group] {
        let bySource = Dictionary(grouping: channels, by: \.source)
        // Stable board order: on-board first, then the I²C board, then the
        // 1-Wire bus — the order the hub's own hardware is wired in.
        let order: [Components.Schemas.CapabilityView.SourcePayload] = [.piPwm, .pca9685, .w1Bus]
        return order.compactMap { source in
            guard let members = bySource[source], !members.isEmpty else { return nil }
            // The API already returns channels in natural order (#38); keep
            // it, with a numeric-aware tie-break so a client-side merge can
            // never interleave 10 between 1 and 2.
            let sorted = members.sorted {
                $0.channel.localizedStandardCompare($1.channel) == .orderedAscending
            }
            let details = sorted.map { Dictionary(uniqueKeysWithValues: flat($0)) }
            let shared = details[0]
                .filter { key, value in details.allSatisfy { $0[key] == value } }
                .sorted { $0.key < $1.key }
                .map { ($0.key, $0.value) }
            return Group(
                source: source, channels: sorted, shared: shared,
                state: chipStates.first { $0.source == source.rawValue }
            )
        }
    }

    /// Only flat scalar values are shown; a nested array or object is skipped
    /// rather than rendered as a debug dump.
    static func flat(_ channel: Components.Schemas.CapabilityView) -> [(String, String)] {
        channel.detail.additionalProperties.value
            .compactMap { key, value -> (String, String)? in
                switch value {
                case let value as String: return (key, value)
                case let value as Int: return (key, String(value))
                case let value as Double: return (key, String(value))
                case let value as Bool: return (key, String(value))
                default: return nil
                }
            }
            .sorted { $0.0 < $1.0 }
    }
}
