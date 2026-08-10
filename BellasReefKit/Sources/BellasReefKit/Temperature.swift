// Bella's Reef iOS — closed source.

import Foundation
import Observation

/// How the operator wants temperatures shown.
///
/// The wire is always Celsius — `SensorReading.unit` is `"degC"` and the hub
/// never converts. Conversion is a presentation concern and lives exactly here,
/// so a value can never round-trip through Fahrenheit and back into a threshold
/// comparison.
public enum TemperatureUnitPreference: String, CaseIterable, Sendable, Identifiable {
    /// Follow the device's region. A US phone reads Fahrenheit, everywhere else
    /// Celsius — the same rule the Weather app uses.
    case automatic
    case celsius
    case fahrenheit

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        }
    }

    /// What `automatic` resolves to, so the picker can say so rather than
    /// leaving the operator to guess which one they are getting.
    public func resolved(locale: Locale = .current) -> UnitTemperature {
        switch self {
        case .celsius: .celsius
        case .fahrenheit: .fahrenheit
        // `.us` rather than `!= .metric`: the UK measurement system is neither,
        // and it reads temperature in Celsius.
        case .automatic: locale.measurementSystem == .us ? .fahrenheit : .celsius
        }
    }
}

/// Turns a Celsius reading from the wire into something to put on screen.
///
/// Deliberately not a `MeasurementFormatter` with `.naturalScale`: that formats
/// number and unit together, and the hero renders them at two different type
/// sizes. Splitting them is a layout requirement, not a preference.
public enum TemperatureDisplay {

    /// The reading, converted for display.
    public static func measurement(
        celsius: Double, as preference: TemperatureUnitPreference, locale: Locale = .current
    ) -> Measurement<UnitTemperature> {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .converted(to: preference.resolved(locale: locale))
    }

    /// The number alone, one decimal place.
    ///
    /// One decimal in both units on purpose. A DS18B20 resolves 0.0625 °C, so
    /// one decimal is already at the edge of what the probe knows; a second
    /// would render noise as precision, and in Fahrenheit it would render
    /// conversion artefacts as precision.
    public static func value(
        celsius: Double, as preference: TemperatureUnitPreference, locale: Locale = .current
    ) -> String {
        let converted = measurement(celsius: celsius, as: preference, locale: locale)
        return converted.value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// `°C` or `°F`.
    public static func symbol(
        for preference: TemperatureUnitPreference, locale: Locale = .current
    ) -> String {
        preference.resolved(locale: locale).symbol
    }

    /// Spoken form for VoiceOver (design brief §7.5: labels carry meaning).
    ///
    /// "22.4 degrees Celsius", not "22.4 °C" — the symbol is read as
    /// "degree sign C" by the screen reader, which is noise.
    public static func spoken(
        celsius: Double, as preference: TemperatureUnitPreference, locale: Locale = .current
    ) -> String {
        let unit = preference.resolved(locale: locale)
        let number = value(celsius: celsius, as: preference, locale: locale)
        return "\(number) degrees \(unit == .fahrenheit ? "Fahrenheit" : "Celsius")"
    }
}

/// Operator preferences that outlive a launch.
///
/// UserDefaults rather than the Keychain: none of this is a secret, and a unit
/// preference that failed to load because the device was locked would be worse
/// than one anybody can read.
@MainActor
@Observable
public final class Preferences {
    private static let unitKey = "com.bellasreef.temperatureUnit"
    private static let primaryKey = "com.bellasreef.primarySensor"

    /// Held, not defaulted at the call site. Writing back to
    /// `UserDefaults.standard` while reading from an injected store would make
    /// the preference appear to save and then reload as whatever it was.
    private let defaults: UserDefaults

    public var temperatureUnit: TemperatureUnitPreference {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Self.unitKey) }
    }

    /// Which probe gets the hero number.
    ///
    /// `nil` means "not chosen", and the Tank tab falls back to the first
    /// reporting sensor rather than showing nothing. Stored so the choice
    /// survives a relaunch — on a tank with a display and a sump probe, which
    /// one is *the* temperature is a standing preference, not a per-session one.
    public var primarySensorId: String? {
        didSet { defaults.set(primarySensorId, forKey: Self.primaryKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.unitKey)
        temperatureUnit = stored.flatMap(TemperatureUnitPreference.init(rawValue:)) ?? .automatic
        primarySensorId = defaults.string(forKey: Self.primaryKey)
    }
}
