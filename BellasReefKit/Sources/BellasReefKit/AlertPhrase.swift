// Bella's Reef iOS — closed source.

import Foundation

/// The Tank tab's alert banner headline: "22.0 °C — below 24.0 °C min", or
/// the honest fallback when the wire withheld the numbers a full sentence
/// needs.
///
/// Mirrors `AuditPhrase` in spirit — a typed wire concept turned into a
/// sentence a person reads at a glance — but for `SensorAlert`'s threshold
/// breach rather than the audit log's action verbs, so it lives in its own
/// file rather than `AuditPhrase.swift`, whose module doc is explicit that
/// it is about audit verbs.
///
/// Review fold: the banner used to print the bare "Out of range" whenever
/// `value`/`threshold`/`unit` were nil — all three optional on
/// `SensorAlert` — and printed the raw unit token (`"pH"`, `"lux"`) for
/// anything that was not literally `"degC"`. Neither read as a sentence a
/// reef keeper wrote.
public enum AlertPhrase {
    /// - Parameters:
    ///   - name: the sensor's display name — always available, so the
    ///     degraded path never has to fall back further than this.
    ///   - value: the reading that crossed the threshold, wire units.
    ///   - threshold: the bound it crossed, the same wire units as `value`.
    ///   - unit: the wire's free-text unit token (`SensorAlert.unit`) — not
    ///     only temperature.
    ///   - isHigh: whether this is the max bound (`above`) or the min
    ///     (`below`).
    ///   - temperatureUnit: the operator's display preference, consulted
    ///     only for `degC`/`degF` alerts — a pH or ppm reading has no
    ///     Celsius/Fahrenheit to convert.
    public static func headline(
        name: String,
        value: Double?,
        threshold: Double?,
        unit: String?,
        isHigh: Bool,
        temperatureUnit: TemperatureUnitPreference,
        locale: Locale = .current
    ) -> String {
        // Missing any of the three means there is no honest sentence to
        // build — say so by name rather than the bare "Out of range" that
        // named nothing (ruling: this is the floor, not a placeholder).
        guard let value, let threshold, let unit else {
            return "\(name) outside its thresholds"
        }

        if unit == "degC" || unit == "degF" {
            let reading = temperatureNumber(value, wireUnit: unit, as: temperatureUnit, locale: locale)
            let limit = temperatureNumber(threshold, wireUnit: unit, as: temperatureUnit, locale: locale)
            let symbol = TemperatureDisplay.symbol(for: temperatureUnit, locale: locale)
            return "\(reading)\(symbol) — \(isHigh ? "above" : "below") "
                + "\(limit)\(symbol) \(isHigh ? "max" : "min")"
        }

        let token = symbol(for: unit)
        return "\(value) \(token) — \(isHigh ? "above" : "below") \(threshold) \(token)"
    }

    /// `degC`'s number is unchanged from what the banner always computed
    /// (`TemperatureDisplay.value(celsius:)`); `degF`'s uses the same
    /// Foundation conversion machinery, just sourced from Fahrenheit rather
    /// than Celsius — nothing invented, `UnitTemperature` already knows how.
    private static func temperatureNumber(
        _ raw: Double, wireUnit: String, as preference: TemperatureUnitPreference, locale: Locale
    ) -> String {
        if wireUnit == "degC" {
            return TemperatureDisplay.value(celsius: raw, as: preference, locale: locale)
        }
        let converted = Measurement(value: raw, unit: UnitTemperature.fahrenheit)
            .converted(to: preference.resolved(locale: locale))
        return converted.value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// The wire's unit token as an operator-facing symbol. `pH`/`ppm` are
    /// already the standard notation; `percent` becomes the symbol it
    /// means. Anything else keeps its own raw token — ruling: no invented
    /// symbols for a unit this build does not recognise.
    private static func symbol(for unit: String) -> String {
        switch unit {
        case "pH": "pH"
        case "ppm": "ppm"
        case "percent": "%"
        default: unit
        }
    }
}
