// Bella's Reef iOS — closed source.
//
// Palette and type, from docs/ios-design-brief.md §1–2 in the backend repo.

import SwiftUI
import UIKit

/// The raw sRGB components of one appearance's palette.
///
/// Plain doubles rather than `Color` so the contrast suite in `ThemeTests` can
/// compute WCAG relative luminance directly — resolving a dynamic `UIColor`
/// needs a trait environment, and these numbers *are* the source the dynamic
/// colours are built from. Ten roles, same semantics in both appearances: a
/// reader who knows the dark app must recognise every colour's meaning in
/// light.
public struct Palette: Sendable {
    public struct RGB: Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public let base: RGB
    public let surface: RGB
    public let surfaceRaised: RGB
    public let primaryText: RGB
    public let secondaryText: RGB
    public let tertiaryText: RGB
    public let accent: RGB
    public let attention: RGB
    public let safety: RGB
    public let silence: RGB

    /// The primary appearance. These values are settled — the contrast suite
    /// pins them; do not "improve" them.
    public static let dark = Palette(
        // Deep blue-grey near-black — 20,000K water, not pure black. Pure black
        // would read as "off" rather than "night".
        base: RGB(0.043, 0.055, 0.075),
        surface: RGB(0.075, 0.090, 0.118),
        surfaceRaised: RGB(0.110, 0.129, 0.165),
        primaryText: RGB(0.918, 0.937, 0.961),
        secondaryText: RGB(0.612, 0.655, 0.706),
        // Lifted twice to clear WCAG AA for normal text, both times by the
        // smallest bump along the same hue that passes.
        //
        // First from (0.392, 0.435, 0.490): that measured **3.78:1** against
        // `base` — fine for large text, a fail for the captions and sensor ids
        // it was actually used on. Design brief §7.5 requires AA for all text
        // and calls out the dimmed stale treatment by name: it must read as
        // quieter, not as decoration. The lift landed at 4.60:1 vs `base`.
        //
        // Then from (0.441, 0.489, 0.551), ruled by David 2026-08-14: the
        // UX-1 contrast suite measured that value at **4.27:1** against
        // `surface` — the row-card ground it also renders on — which the old
        // vs-`base`-only check never saw. A 3% lift clears both grounds:
        // 4.84:1 vs `base`, 4.50:1 vs `surface`. (vs `surfaceRaised` it is
        // 4.05:1 — no text renders on that pair today; the suite scopes it
        // out deliberately.)
        tertiaryText: RGB(0.454, 0.504, 0.568),
        accent: RGB(0.153, 0.831, 0.808),
        attention: RGB(0.984, 0.749, 0.286),
        safety: RGB(0.937, 0.325, 0.314),
        silence: RGB(0.639, 0.549, 0.965)
    )

    /// The secondary appearance, for daylight use. Same hue for every role —
    /// teal accent, amber attention, red safety, violet silence — darkened
    /// until the contrast suite passes on a light ground.
    public static let light = Palette(
        // Cool near-white blue-grey — daylight over water, not paper. The same
        // reasoning as dark's not-pure-black, from the opposite pole: pure
        // white would read as a document, and this app is a window.
        base: RGB(0.929, 0.941, 0.957),
        surface: RGB(0.957, 0.965, 0.976),
        surfaceRaised: RGB(0.984, 0.988, 0.992),
        primaryText: RGB(0.090, 0.112, 0.145),
        secondaryText: RGB(0.290, 0.329, 0.380),
        tertiaryText: RGB(0.365, 0.408, 0.463),
        // The dark accent teal reads 1.61:1 on this ground — invisible. Same
        // hue, pulled down until it clears 3:1 (non-text floor) with margin.
        accent: RGB(0.000, 0.478, 0.463),
        // Amber darkens toward ochre; that is the cost of AA amber-as-text on
        // a light ground, and it still reads as "attention, not alarm".
        attention: RGB(0.573, 0.365, 0.000),
        // Recognisably the same red as dark's safety, deepened to clear AA.
        safety: RGB(0.788, 0.153, 0.145),
        silence: RGB(0.416, 0.318, 0.796)
    )
}

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

    /// A colour that resolves per appearance: `Palette.light` when the trait
    /// environment says light, `Palette.dark` for dark *and* unspecified —
    /// dark is primary, so it is also the answer when nobody has said.
    private static func adaptive(_ role: @escaping @Sendable (Palette) -> Palette.RGB) -> Color {
        Color(UIColor { traits in
            let palette: Palette = traits.userInterfaceStyle == .light ? .light : .dark
            let c = role(palette)
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        })
    }

    // MARK: Base

    public static let base = adaptive { $0.base }
    public static let surface = adaptive { $0.surface }
    public static let surfaceRaised = adaptive { $0.surfaceRaised }

    // MARK: Content

    public static let primaryText = adaptive { $0.primaryText }
    public static let secondaryText = adaptive { $0.secondaryText }
    public static let tertiaryText = adaptive { $0.tertiaryText }

    // MARK: Semantic

    /// The single accent: interactive elements and the healthy state. One
    /// accent everywhere — the tank carries the colour, the UI stays nearly
    /// monochrome.
    public static let accent = adaptive { $0.accent }

    /// Attention, not alarm: stale sensor, pending approval, override active.
    public static let attention = adaptive { $0.attention }

    /// Safety only. See the type-level note — this is not an error colour.
    public static let safety = adaptive { $0.safety }

    /// A probe that stopped reporting: we do not know, as distinct from we know
    /// and it is bad.
    ///
    /// Deliberately neither `attention` nor `safety`. Amber would make "the tank
    /// is slightly cold" and "nobody has any idea what the tank is doing" the
    /// same colour, and the second is worse. Red would claim a certainty about
    /// the water that silence is precisely the absence of. Violet sits outside
    /// the temperature metaphor altogether, which is the point: this band is
    /// about the instrumentation, not the tank.
    public static let silence = adaptive { $0.silence }

    // MARK: Type

    /// The hero number on the Tank tab. Rounded because a temperature is a
    /// reading, not a data point in a spreadsheet.
    /// Base size for the hero reading. Not a `Font`: a fixed-size system font
    /// ignores Dynamic Type entirely, and design brief §7.5 requires hero
    /// numbers to scale. Views pass this through `@ScaledMetric` and build the
    /// font from the scaled value — see `TemperatureHero`.
    public static let heroNumberSize: CGFloat = 72
    public static let sectionTitle = Font.system(.headline, design: .rounded)
    public static let value = Font.system(.body, design: .rounded).monospacedDigit()
    public static let caption = Font.system(.caption, design: .rounded)

    // MARK: Chart

    /// The sub-8% floor shading `MiniDayCurve` and `ScheduleChart` both draw
    /// under a duty curve (`Dimming.minUsableDuty`) — hoisted here (deferred-
    /// minors review fold) so the tint and opacity can never drift apart
    /// between the two charts the way two independently-typed literals can.
    public static let floorBand = tertiaryText.opacity(0.12)
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
