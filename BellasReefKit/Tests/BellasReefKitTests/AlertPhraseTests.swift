// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

/// Deferred-minors Task 3: `TankView`'s alert banner used to print the bare
/// "Out of range" whenever `value`/`threshold`/`unit` were nil (all three
/// optional on `SensorAlert`), and the raw wire token (`"pH"`, `"lux"`) for
/// anything that was not literally `"degC"`. `AlertPhrase.headline` is the
/// hoisted, testable replacement.
@Suite("AlertPhrase")
struct AlertPhraseTests {
    private static let usLocale = Locale(identifier: "en_US")

    @Test("all fields present renders the existing degC sentence, unchanged")
    func fullSentenceDegC() {
        let text = AlertPhrase.headline(
            name: "Display tank", value: 22.0, threshold: 24.0, unit: "degC",
            isHigh: false, temperatureUnit: .celsius, locale: Self.usLocale
        )
        #expect(text == "22.0°C — below 24.0°C min")
    }

    @Test("degF converts through the same Foundation machinery as degC")
    func fullSentenceDegF() {
        let text = AlertPhrase.headline(
            name: "Display tank", value: 71.6, threshold: 75.2, unit: "degF",
            isHigh: true, temperatureUnit: .fahrenheit, locale: Self.usLocale
        )
        #expect(text == "71.6°F — above 75.2°F max")
    }

    @Test("a missing value says the sensor is outside its thresholds, never 'Out of range'")
    func missingValue() {
        let text = AlertPhrase.headline(
            name: "Sump probe", value: nil, threshold: 24.0, unit: "degC",
            isHigh: true, temperatureUnit: .celsius, locale: Self.usLocale
        )
        #expect(text == "Sump probe outside its thresholds")
    }

    @Test("a missing threshold says the sensor is outside its thresholds")
    func missingThreshold() {
        let text = AlertPhrase.headline(
            name: "Sump probe", value: 25.0, threshold: nil, unit: "degC",
            isHigh: true, temperatureUnit: .celsius, locale: Self.usLocale
        )
        #expect(text == "Sump probe outside its thresholds")
    }

    @Test("a missing unit says the sensor is outside its thresholds")
    func missingUnit() {
        let text = AlertPhrase.headline(
            name: "Sump probe", value: 25.0, threshold: 24.0, unit: nil,
            isHigh: true, temperatureUnit: .celsius, locale: Self.usLocale
        )
        #expect(text == "Sump probe outside its thresholds")
    }

    @Test("pH keeps its standard notation")
    func pH() {
        let text = AlertPhrase.headline(
            name: "Reactor pH", value: 6.2, threshold: 6.5, unit: "pH",
            isHigh: false, temperatureUnit: .celsius, locale: Self.usLocale
        )
        #expect(text == "6.2 pH — below 6.5 pH")
    }

    @Test("ppm keeps its standard notation")
    func ppm() {
        let text = AlertPhrase.headline(
            name: "Nitrate probe", value: 12.0, threshold: 10.0, unit: "ppm",
            isHigh: true, temperatureUnit: .celsius, locale: Self.usLocale
        )
        #expect(text == "12.0 ppm — above 10.0 ppm")
    }

    @Test("percent becomes the % symbol")
    func percent() {
        let text = AlertPhrase.headline(
            name: "Humidity", value: 45.0, threshold: 50.0, unit: "percent",
            isHigh: true, temperatureUnit: .celsius, locale: Self.usLocale
        )
        #expect(text == "45.0 % — above 50.0 %")
    }

    @Test("an unrecognised unit keeps its own raw token — no invented symbols")
    func unknownUnit() {
        let text = AlertPhrase.headline(
            name: "Light meter", value: 3.0, threshold: 5.0, unit: "lux",
            isHigh: false, temperatureUnit: .celsius, locale: Self.usLocale
        )
        #expect(text == "3.0 lux — below 5.0 lux")
    }
}
