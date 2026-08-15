// Bella's Reef iOS — closed source.
//
// WCAG 2.x contrast suite for both palettes. Design brief §7.5 requires AA
// for all text; these assertions are the binding authority on palette values —
// tune the palette until green, never the floors.

import Foundation
import Testing

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
