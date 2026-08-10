// Bella's Reef iOS — closed source.

import XCTest

/// The app's first write path, driven through the UI against a real hub.
///
/// Bench test, not CI — same rules as `PairingJourneyTests`: it needs a hub on
/// the LAN, and it edits that hub's configuration.
///
/// Why this exists at all, when the endpoints already have backend tests: the
/// founding bug of this project was a read path that looked green end to end
/// while the wire was dead. Every unit test passed, the metrics endpoint served
/// a live temperature, and nothing was ever published. A write path has exactly
/// the same shape of failure available to it — a form that validates, a button
/// that spins, a sheet that dismisses, and nothing that reaches Postgres.
///
/// So the assertions here deliberately do not trust the form. After saving, the
/// sheet is reopened, and `DeviceCatalog` refills it from `GET /api/v1/sensors`.
/// What is asserted is therefore what came *back from the hub*, not what was
/// typed in.
final class SensorWriteTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testRenameAndThresholdsRoundTripThroughTheHub() throws {
        let app = XCUIApplication()
        app.launch()

        let tankTab = app.tabBars.buttons["Tank"]
        XCTAssertTrue(
            tankTab.waitForExistence(timeout: 30),
            "not paired — run PairingJourneyTests first, or open a pairing window"
        )

        // The values written. Deliberately in whatever unit the app is showing:
        // the assertion is a round trip, so it holds in °C or °F without the
        // test needing to know which.
        let name = "Display tank"
        let minimum = "70.0"
        let maximum = "82.0"
        let margin = "1.0"

        openDetailSheet(app)
        replace(app.textFields["sensor-name"], with: name)
        replace(app.textFields["threshold-minimum"], with: minimum)
        replace(app.textFields["threshold-maximum"], with: maximum)
        replace(app.textFields["threshold-margin"], with: margin)

        app.buttons["save-sensor"].tap()

        // The sheet closing is the app's claim that the write succeeded. It is
        // not evidence — that comes next.
        XCTAssertTrue(
            app.textFields["sensor-name"].waitForNonExistence(timeout: 15),
            "the sheet stayed open, so the save was refused"
        )

        // The name on the Tank tab is rendered from the catalog, which was
        // refilled from the hub after the write.
        XCTAssertTrue(
            app.staticTexts[name].waitForExistence(timeout: 10),
            "the Tank tab did not pick up the new name"
        )

        // Reopen: every field below is hub state, re-read over REST and
        // re-converted, not the text that was typed.
        openDetailSheet(app)
        XCTAssertEqual(app.textFields["sensor-name"].value as? String, name)
        XCTAssertEqual(app.textFields["threshold-minimum"].value as? String, minimum)
        XCTAssertEqual(app.textFields["threshold-maximum"].value as? String, maximum)
        XCTAssertEqual(
            app.textFields["threshold-margin"].value as? String, margin,
            "a clear margin is a difference, not a temperature — a round trip that "
                + "shifts by 32 means it was converted as an absolute value"
        )
        app.buttons["Cancel"].tap()
    }

    func testAnUnusableBandIsRefusedInlineByTheHub() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Tank"].waitForExistence(timeout: 30), "not paired")

        openDetailSheet(app)
        // A margin wider than half the band leaves no reading that could ever
        // clear the alert. The hub refuses it; the app must show why rather than
        // failing silently or inventing its own wording.
        replace(app.textFields["threshold-minimum"], with: "70.0")
        replace(app.textFields["threshold-maximum"], with: "72.0")
        replace(app.textFields["threshold-margin"], with: "9.0")

        app.buttons["save-sensor"].tap()

        let error = app.staticTexts["threshold-error"]
        XCTAssertTrue(
            error.waitForExistence(timeout: 15),
            "the hub refused the band and the sheet said nothing"
        )
        // The hub's own explanation, not a generic failure.
        XCTAssertTrue(
            error.label.localizedCaseInsensitiveContains("half the band"),
            "the inline error lost the hub's explanation: \(error.label)"
        )
        XCTAssertFalse(
            error.label.hasPrefix("Value error"),
            "Pydantic's envelope leaked into the UI: \(error.label)"
        )
        // Refused means unchanged: the sheet is still open on the bad input.
        XCTAssertTrue(app.textFields["sensor-name"].exists)
        app.buttons["Cancel"].tap()
    }

    // MARK: helpers

    private func openDetailSheet(_ app: XCUIApplication) {
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+\\.[0-9].*$")
        ).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 45), "no reading to tap")
        hero.tap()
        XCTAssertTrue(
            app.textFields["sensor-name"].waitForExistence(timeout: 10),
            "the sensor detail sheet did not open"
        )
    }

    /// Clear a field and type into it.
    ///
    /// An empty threshold field shows its "—" placeholder as its value, which is
    /// not text to delete; deleting it character by character would send a
    /// backspace into an empty field and, on some rows, dismiss the keyboard.
    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "missing field")
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty, current != "—" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }
}
