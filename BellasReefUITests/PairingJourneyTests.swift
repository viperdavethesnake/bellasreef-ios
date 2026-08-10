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

        // 1. Discovery. Bonjour, then resolution — the row only appears once the
        //    hub has actually answered a connection.
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

        // 3. Pairing lands on the Tank tab. If the hub had no open window this
        //    would sit on "Waiting for approval" instead, so the assertion is
        //    also checking that a window was open when the test ran.
        let tankTab = app.tabBars.buttons["Tank"]
        XCTAssertTrue(
            tankTab.waitForExistence(timeout: 20),
            "did not reach the dashboard — check for a pending-approval or recovery state"
        )

        // 4. A live reading. The hero shows "—" until the first sensor frame, so
        //    waiting for a digit is waiting for the stream to actually deliver.
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+\\.[0-9]$")
        ).firstMatch
        XCTAssertTrue(
            hero.waitForExistence(timeout: 45),
            "no temperature rendered — frames are not reaching the app"
        )

        // 5. And the safety line reports honestly rather than optimistically.
        let allClear = app.staticTexts["All clear"]
        XCTAssertTrue(allClear.waitForExistence(timeout: 15), "status line never reached All clear")

        XCTContext.runActivity(named: "paired dashboard") { activity in
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            activity.add(shot)
        }
    }
}
