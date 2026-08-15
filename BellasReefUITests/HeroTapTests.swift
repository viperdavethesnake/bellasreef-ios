// Bella's Reef iOS — closed source.

import XCTest

/// UX-5: the review reported that tapping the hero temperature number does
/// nothing, and only the probe-name row above it opens the sensor detail
/// sheet.
///
/// `PrimaryReading` (`BellasReef/Views/TankView.swift`) already wraps the
/// whole hero block — name, number, and sparkline — in one
/// `Button { onInspect(sensorId) }` with `.buttonStyle(.plain)`. That reads
/// as a single tap target by construction, so the question this test settles
/// is whether the *number's own frame* actually hit-tests, or whether the
/// review's synthetic tap missed it.
///
/// It taps at the number's own coordinate — `coordinate(withNormalizedOffset:)`
/// on the hero `StaticText`, not `element.tap()` on the enclosing button,
/// which would resolve to the button's activation point and could mask a
/// partial hit-test hole inside the `TimelineView`-wrapped label.
///
/// Bench-only, like the other UI tests here: it needs a hub already paired
/// on the LAN, and it must not pair, adopt, revoke, or command anything —
/// it only opens and closes the sensor detail sheet.
///
/// **Verdict (2026-08-14): UX-5 is a tooling false negative, not a real
/// hit-testing bug.** Tapping the hero number's own frame — coordinate-based,
/// not `element.tap()` on the button — opens the sensor detail sheet cleanly.
/// No production code changed; this test stays as the regression guard.
///
/// One plausible source for the original finding, observed while writing
/// this test: with an active alert on the hub, its banner sits directly
/// above the hero and its headline also starts with a number
/// ("76.0°F — below 76.0°F min"), so a loose "starts with digits" element
/// query lands on the banner instead of the hero — this test's own first
/// draft made exactly that mistake, hence the fully-anchored regex below.
/// Whether that is what the review's tooling did is not confirmed, only
/// plausible.
final class HeroTapTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testTappingTheHeroNumberOpensTheSensorDetailSheet() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Tank"].waitForExistence(timeout: 30), "not paired")

        // The hero number's own StaticText — a bare value like "74.2", full
        // string match only. An alert banner can be showing above the hero
        // (its headline also starts with digits, e.g. "76.0°F — below 76.0°F
        // min"), so a loose "starts with digits" predicate is not enough to
        // land on the hero and not the banner; anchoring both ends of the
        // regex is what keeps this on the bare number.
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^-?[0-9]+\\.[0-9]+$")
        ).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 45), "no hero reading to tap")

        // Tap the hero element's own frame, not the button's activation
        // point. This is the whole point of the test: a synthetic tap
        // targeted at the number itself, the exact spot UX-5 says is dead.
        hero.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // The sheet's rename field is the least ambiguous proof it opened —
        // present as soon as the sheet appears, before any network round trip.
        let sheetOpened = app.textFields["sensor-name"].waitForExistence(timeout: 10)
        XCTAssertTrue(sheetOpened, "tapping the hero number did not open the sensor detail sheet")

        // Belt and suspenders: the primary-sensor control the brief calls
        // out by name. Checked for existence only — never tapped, since
        // changing primary-sensor is a write against the hub's preferences.
        let primaryControl = app.buttons["Make primary"].exists || app.buttons["Primary sensor"].exists
        XCTAssertTrue(primaryControl, "sheet opened but not the expected SensorDetailSheet")

        // Leave no state behind: dismiss without saving.
        app.buttons["Cancel"].tap()
    }
}
