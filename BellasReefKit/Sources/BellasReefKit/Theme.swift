// Bella's Reef iOS — closed source.
//
// Palette and type, from docs/ios-design-brief.md §1–2 in the backend repo.

import SwiftUI

/// The app's colour system.
///
/// Two rules from the brief are encoded here rather than left to discipline,
/// because both are the kind of thing that erodes one reasonable-looking commit
/// at a time:
///
/// 1. **Dark is primary.** This app opens at night beside an actinic-lit tank.
///    A white screen is a flashbang. Light mode is supported and secondary.
/// 2. **Red means safety, and nothing else, ever.** Interlock latched,
///    fail-safe fired, clock untrusted. Not errors, not validation, not a
///    failed network call. When red appears it must mean something.
public enum Theme {

    // MARK: Base

    /// Deep blue-grey near-black — 20,000K water, not pure black. Pure black
    /// would read as "off" rather than "night".
    public static let base = Color(red: 0.043, green: 0.055, blue: 0.075)
    public static let surface = Color(red: 0.075, green: 0.090, blue: 0.118)
    public static let surfaceRaised = Color(red: 0.110, green: 0.129, blue: 0.165)

    // MARK: Content

    public static let primaryText = Color(red: 0.918, green: 0.937, blue: 0.961)
    public static let secondaryText = Color(red: 0.612, green: 0.655, blue: 0.706)
    public static let tertiaryText = Color(red: 0.392, green: 0.435, blue: 0.490)

    // MARK: Semantic

    /// The single accent: interactive elements and the healthy state. One
    /// accent everywhere — the tank carries the colour, the UI stays nearly
    /// monochrome.
    public static let accent = Color(red: 0.153, green: 0.831, blue: 0.808)

    /// Attention, not alarm: stale sensor, pending approval, override active.
    public static let attention = Color(red: 0.984, green: 0.749, blue: 0.286)

    /// Safety only. See the type-level note — this is not an error colour.
    public static let safety = Color(red: 0.937, green: 0.325, blue: 0.314)

    // MARK: Type

    /// The hero number on the Tank tab. Rounded because a temperature is a
    /// reading, not a data point in a spreadsheet.
    public static let heroNumber = Font.system(size: 72, weight: .light, design: .rounded)
    public static let sectionTitle = Font.system(.headline, design: .rounded)
    public static let value = Font.system(.body, design: .rounded).monospacedDigit()
    public static let caption = Font.system(.caption, design: .rounded)
}

/// How a tank is doing, in the only three states worth a colour.
///
/// Deliberately not an "error" case: a network failure is not a safety event
/// and must never light the tank red.
public enum HealthTone: Sendable {
    case allClear
    case attention
    case safety

    public var color: Color {
        switch self {
        case .allClear: Theme.accent
        case .attention: Theme.attention
        case .safety: Theme.safety
        }
    }

    public var label: String {
        switch self {
        case .allClear: "All clear"
        case .attention: "Needs a look"
        case .safety: "Safety"
        }
    }
}

extension View {
    /// Content-first background. Glass belongs to the navigation layer only —
    /// a temperature reading never shimmers (brief §1).
    public func reefBackground() -> some View {
        background(Theme.base.ignoresSafeArea())
    }
}
