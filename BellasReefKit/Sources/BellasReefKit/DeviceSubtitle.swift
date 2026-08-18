// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC

/// The one-line identity under an adopted device's name: driver, physical
/// channel, role.
///
/// The channel is what a binding names — a PWM channel number, or a 1-Wire ROM.
/// A DS18B20's driver id is `ds18b20-<rom>`, so for that family the channel
/// would repeat what the driver id just said (UX review A7:
/// `ds18b20-28-000000bfe244 · 28-000000bfe244`). When the driver id already
/// ends with the channel, say it once.
public enum DeviceSubtitle {
    public static func text(driverId: String, channel: String?, role: String?) -> String {
        var parts = [driverId]
        if let channel, !driverId.hasSuffix(channel) {
            parts.append(Int(channel) != nil ? "ch \(ChannelLabel.humanNumber(channel))" : channel)
        }
        if let role { parts.append(role) }
        return parts.joined(separator: " · ")
    }
}
