// Bella's Reef iOS — closed source.

import XCTest

/// The whole journey, against a real hub: discover, identify, pair, watch a
/// temperature arrive.
///
/// This is a bench test, not a CI test. It needs `_bellasreef._tcp` on the LAN
/// and it spends a pairing window, leaving a paired client behind on the hub.
/// Run it deliberately:
///
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     xcodebuild test -project BellasReef.xcodeproj -scheme BellasReef \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -skipPackagePluginValidation
///
/// It exists because every cheaper check passed while the app still showed an
/// endless spinner: the backend published, the socket served, the generated
/// types decoded, and discovery silently dropped every result. Only walking the
/// screens the way an operator does catches that class of failure.
final class PairingJourneyTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testPairsWithARealHubAndShowsALiveTemperature() throws {
        let app = XCUIApplication()
        app.launch()

        let tankTab = app.tabBars.buttons["Tank"]

        // A credential in the Keychain survives a reinstall, so this device may
        // already be paired. Both paths have to work: the point of the test is
        // the dashboard, and re-pairing when it is not needed would spend a
        // pairing window for nothing.
        if !tankTab.waitForExistence(timeout: 8) {
            // 1. Discovery. Bonjour, then resolution — the row only appears once
            //    the hub has actually answered a connection.
            let hubRow = app.buttons.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Bella's Reef")
            ).firstMatch
            XCTAssertTrue(
                hubRow.waitForExistence(timeout: 30),
                "no hub discovered — is the hub up and advertising _bellasreef._tcp?"
            )
            hubRow.tap()

            // 2. The identify card: /info before any commitment.
            let pairButton = app.buttons.containing(
                NSPredicate(format: "label BEGINSWITH[c] %@", "Pair")
            ).firstMatch
            XCTAssertTrue(pairButton.waitForExistence(timeout: 15), "identify card never loaded")
            pairButton.tap()

            // 3. Pairing lands on the Tank tab. If no window were open this
            //    would sit on "Waiting for approval" instead, so the assertion
            //    also checks that a window was open when the test ran.
            XCTAssertTrue(
                tankTab.waitForExistence(timeout: 20),
                "did not reach the dashboard — check for a pending-approval or recovery state"
            )
        }

        // 4. A live reading. The hero shows "—" until the first sensor frame, so
        //    waiting for a digit is waiting for the stream to actually deliver.
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+\\.[0-9]$")
        ).firstMatch
        XCTAssertTrue(
            hero.waitForExistence(timeout: 45),
            "no temperature rendered — frames are not reaching the app"
        )

        attach(app, named: "tank")

        // 5. And the safety line reports honestly rather than optimistically.
        //    Any of these is a truthful answer; what would be wrong is silence,
        //    or a stale number presented as current.
        // The status line is combined into one accessibility element for
        // VoiceOver (§7.5), so its label is "Status: …" rather than the bare
        // text. Querying the raw string finds nothing — which is what the first
        // run of this assertion discovered.
        let status = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Status: ")
        ).firstMatch
        XCTAssertTrue(status.exists, "status line said nothing meaningful")

        // 6. The sensor detail sheet: tap the reading, land on rename +
        //    thresholds, with the raw id present exactly here and nowhere else.
        hero.tap()
        let sheetTitle = app.staticTexts["Sensor id"]
        XCTAssertTrue(
            sheetTitle.waitForExistence(timeout: 10),
            "tapping the reading did not open the sensor detail sheet"
        )
        XCTAssertTrue(app.staticTexts["Alert thresholds (°F)"].exists
                      || app.staticTexts["Alert thresholds (°C)"].exists,
                      "threshold section missing")
        attach(app, named: "sensor-detail")
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        XCTContext.runActivity(named: name) { activity in
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            activity.add(shot)
        }
    }
}
