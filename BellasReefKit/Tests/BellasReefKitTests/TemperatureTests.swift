// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

@Suite("Temperature display")
struct TemperatureTests {

    @Test("Celsius passes through untouched")
    func celsius() {
        #expect(TemperatureDisplay.value(celsius: 24.5, as: .celsius, locale: Locale(identifier: "en_US")) == "24.5")
    }

    @Test("Fahrenheit converts")
    func fahrenheit() {
        // 24.5 °C = 76.1 °F
        #expect(TemperatureDisplay.value(celsius: 24.5, as: .fahrenheit, locale: Locale(identifier: "en_US")) == "76.1")
    }

    @Test("a US locale resolves automatic to Fahrenheit")
    func automaticInTheStates() {
        #expect(TemperatureUnitPreference.automatic.resolved(locale: Locale(identifier: "en_US")) == .fahrenheit)
    }

    @Test("a metric locale resolves automatic to Celsius")
    func automaticElsewhere() {
        #expect(TemperatureUnitPreference.automatic.resolved(locale: Locale(identifier: "de_DE")) == .celsius)
    }

    @Test("the UK reads Celsius despite its own measurement system")
    func theUnitedKingdom() {
        // The UK is neither `.metric` nor `.us`, so a `!= .metric` test would
        // put °F on a British phone. This is why the check is `== .us`.
        #expect(TemperatureUnitPreference.automatic.resolved(locale: Locale(identifier: "en_GB")) == .celsius)
    }

    @Test("symbols match the resolved unit")
    func symbols() {
        #expect(TemperatureDisplay.symbol(for: .celsius) == "°C")
        #expect(TemperatureDisplay.symbol(for: .fahrenheit) == "°F")
    }

    @Test("VoiceOver says the unit rather than the symbol")
    func spoken() {
        let said = TemperatureDisplay.spoken(
            celsius: 24.5, as: .celsius, locale: Locale(identifier: "en_US")
        )
        #expect(said == "24.5 degrees Celsius")
    }

    @Test("one decimal place, because the probe has no more to give")
    func precision() {
        // A DS18B20 resolves 0.0625 °C. A second decimal would render
        // quantisation noise — and in Fahrenheit, conversion artefacts — as
        // though they were measurements.
        let f = TemperatureDisplay.value(
            celsius: 23.8125, as: .fahrenheit, locale: Locale(identifier: "en_US")
        )
        #expect(f == "74.9")
    }

    @Test("the stored preference survives a relaunch")
    @MainActor
    func persistence() {
        let suite = UserDefaults(suiteName: "temperature-tests")!
        suite.removePersistentDomain(forName: "temperature-tests")

        let first = Preferences(defaults: suite)
        #expect(first.temperatureUnit == .automatic)
        first.temperatureUnit = .fahrenheit

        #expect(Preferences(defaults: suite).temperatureUnit == .fahrenheit)
        suite.removePersistentDomain(forName: "temperature-tests")
    }
}
