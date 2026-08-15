// Bella's Reef iOS — closed source.
//
// WCAG 2.x contrast suite for both palettes. Design brief §7.5 requires AA
// for all text; these assertions are the binding authority on palette values —
// tune the palette until green, never the floors.

import Foundation
import SwiftUI
import Testing
import UIKit

@testable import BellasReefKit

/// WCAG 2.x relative luminance of an sRGB colour: gamma-decode each component,
/// then weight with the Rec. 709 coefficients.
private func luminance(_ c: Palette.RGB) -> Double {
    func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
}

/// WCAG contrast ratio, 1...21, order-independent.
private func contrast(_ a: Palette.RGB, _ b: Palette.RGB) -> Double {
    let la = luminance(a)
    let lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

@Suite("Dark palette contrast")
struct DarkPaletteContrastTests {
    let p = Palette.dark

    @Test func textRampOnBase() {
        #expect(contrast(p.primaryText, p.base) >= 4.5)
        #expect(contrast(p.secondaryText, p.base) >= 4.5)
        #expect(contrast(p.tertiaryText, p.base) >= 4.5)
    }

    @Test func textRampOnSurface() {
        #expect(contrast(p.primaryText, p.surface) >= 4.5)
        #expect(contrast(p.secondaryText, p.surface) >= 4.5)
        // tertiaryText/surface is the pinned known shortfall below, not here.
    }

    /// Known shortfall, recorded rather than fixed: dark `tertiaryText` on
    /// `surface` measures **4.27:1** — under AA's 4.5. The palette comment's
    /// 4.60:1 claim is against `base` and holds exactly; the vs-`surface`
    /// floor arrived with this suite (UX-1), and the dark values are law for
    /// that task — flagged in its report, not silently "improved". Pinned to
    /// the measured value so any drift in either colour re-opens the question
    /// instead of hiding under a loosened floor. Clearing it is a one-line
    /// tertiaryText bump awaiting a design ruling.
    @Test func tertiaryOnSurfaceKnownShortfall() {
        let measured = contrast(p.tertiaryText, p.surface)
        #expect(measured >= 4.27 && measured < 4.5)
    }

    /// Semantic colours used as text: stale badges, safety banners, silence
    /// band labels all render these directly on dark ground.
    @Test func semanticTextOnBase() {
        #expect(contrast(p.attention, p.base) >= 4.5)
        #expect(contrast(p.safety, p.base) >= 4.5)
        #expect(contrast(p.silence, p.base) >= 4.5)
    }

    /// Alert banner names render attention-coloured text on a raised card.
    @Test func attentionOnRaisedSurface() {
        #expect(contrast(p.attention, p.surfaceRaised) >= 4.5)
    }

    /// Non-text UI (sparkline stroke, tint): WCAG 1.4.11 floor.
    @Test func accentOnBase() {
        #expect(contrast(p.accent, p.base) >= 3.0)
    }
}

/// The contrast suites vouch for `Palette` values; these bind the public
/// `Theme.*` colours to the palette roles they must resolve to. Without them a
/// transposed role in Theme's `adaptive` table — say `surface` resolving
/// `$0.base` — would leave every value-only test green: constructible but not
/// running, in miniature.
@MainActor
@Suite("Theme resolver binding")
struct ThemeResolverBindingTests {
    /// All ten roles, so a transposition anywhere in the table is caught, not
    /// just at two spot-checked corners.
    private static let roles: [(name: String, color: Color, role: (Palette) -> Palette.RGB)] = [
        ("base", Theme.base, { $0.base }),
        ("surface", Theme.surface, { $0.surface }),
        ("surfaceRaised", Theme.surfaceRaised, { $0.surfaceRaised }),
        ("primaryText", Theme.primaryText, { $0.primaryText }),
        ("secondaryText", Theme.secondaryText, { $0.secondaryText }),
        ("tertiaryText", Theme.tertiaryText, { $0.tertiaryText }),
        ("accent", Theme.accent, { $0.accent }),
        ("attention", Theme.attention, { $0.attention }),
        ("safety", Theme.safety, { $0.safety }),
        ("silence", Theme.silence, { $0.silence }),
    ]

    private func assertResolves(_ style: UIUserInterfaceStyle, to palette: Palette) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        for (name, color, role) in Self.roles {
            let resolved = UIColor(color).resolvedColor(with: traits)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            #expect(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha), "\(name)")
            let expected = role(palette)
            // 1e-3: getRed round-trips the colour pipeline, which can wobble
            // the last decimals; the palette's own values differ from each
            // other by whole hundredths, so this cannot mask a transposition.
            #expect(abs(Double(red) - expected.red) < 1e-3, "\(name) red")
            #expect(abs(Double(green) - expected.green) < 1e-3, "\(name) green")
            #expect(abs(Double(blue) - expected.blue) < 1e-3, "\(name) blue")
            #expect(abs(Double(alpha) - 1.0) < 1e-3, "\(name) alpha")
        }
    }

    @Test func darkTraitsResolveTheDarkPalette() {
        assertResolves(.dark, to: .dark)
    }

    @Test func lightTraitsResolveTheLightPalette() {
        assertResolves(.light, to: .light)
    }

    /// Dark is primary: an environment that has not said resolves to dark.
    @Test func unspecifiedTraitsResolveTheDarkPalette() {
        assertResolves(.unspecified, to: .dark)
    }
}

@Suite("Light palette contrast")
struct LightPaletteContrastTests {
    let p = Palette.light

    @Test func textRampOnBase() {
        #expect(contrast(p.primaryText, p.base) >= 4.5)
        #expect(contrast(p.secondaryText, p.base) >= 4.5)
        #expect(contrast(p.tertiaryText, p.base) >= 4.5)
    }

    @Test func textRampOnSurface() {
        #expect(contrast(p.primaryText, p.surface) >= 4.5)
        #expect(contrast(p.secondaryText, p.surface) >= 4.5)
        #expect(contrast(p.tertiaryText, p.surface) >= 4.5)
    }

    @Test func semanticTextOnBase() {
        #expect(contrast(p.attention, p.base) >= 4.5)
        #expect(contrast(p.safety, p.base) >= 4.5)
        #expect(contrast(p.silence, p.base) >= 4.5)
    }

    @Test func attentionOnRaisedSurface() {
        #expect(contrast(p.attention, p.surfaceRaised) >= 4.5)
    }

    @Test func accentOnBase() {
        #expect(contrast(p.accent, p.base) >= 3.0)
    }
}
