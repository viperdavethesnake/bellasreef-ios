// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Bella's Reef LLC
import Testing

@testable import BellasReefKit

/// UX review A7: the adopted-device subtitle read
/// `ds18b20-28-000000bfe244 · 28-000000bfe244 · temperature` — the driver id
/// already carries the ROM, so the channel repeated it.
@Suite("Device subtitle")
struct DeviceSubtitleTests {
    @Test("a 1-Wire channel that the driver id already ends with is not repeated")
    func romOnce() {
        let s = DeviceSubtitle.text(driverId: "ds18b20-28-000000bfe244",
                                    channel: "28-000000bfe244", role: "temperature")
        #expect(s == "ds18b20-28-000000bfe244 · temperature")
    }

    @Test("a PWM channel number is shown as the human channel, after the driver")
    func pwmChannel() {
        let s = DeviceSubtitle.text(driverId: "pca9685", channel: "0", role: "light")
        #expect(s == "pca9685 · ch 1 · light")
    }

    @Test("no channel, no role: the driver alone")
    func bare() {
        #expect(DeviceSubtitle.text(driverId: "fake", channel: nil, role: nil) == "fake")
    }
}
