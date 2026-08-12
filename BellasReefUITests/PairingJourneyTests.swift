// Bella's Reef iOS — closed source.

import XCTest

/// The whole journey, against a real hub: discover, identify, pair, watch a
/// temperature arrive.
///
/// This is a bench test, not a CI test. It needs `_bellasreef._tcp` on the LAN
/// and it can spend a pairing window, leaving a paired client behind on the hub.
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
///
/// ## Why this file is shaped the way it is
///
/// It used to be one test that wrapped the pairing steps in
/// `if !tankTab.waitForExistence(timeout: 8)`. A Keychain credential survives a
/// reinstall, so on any device that had ever paired that branch was skipped —
/// silently, and reported as a pass. The steps least likely to run were the
/// pairing ones, which are the steps this file is named after and the ones the
/// 2026-08-12 review found broken.
///
/// So the pairing journey is its own test now, and when it cannot run it
/// **skips**, loudly, with the reason and the way to force it. A skip is a
/// result. A green tick over an unexecuted branch is a lie.
final class PairingJourneyTests: XCTestCase {

    /// Set `TEST_RUNNER_BELLASREEF_UITEST_REPAIR=1` on the xcodebuild command to
    /// force the pairing journey on a device that is already paired. It clears
    /// the stored credential first, so it does spend a pairing window or leave a
    /// second client on the hub — which is exactly why it is opt-in.
    ///
    /// The `TEST_RUNNER_` prefix is xcodebuild's forwarding convention: only
    /// variables carrying it reach the test-runner process, with the prefix
    /// stripped, which is why the code below reads the bare name. (A scheme
    /// environment variable set in Xcode arrives bare as well.)
    private var repairRequested: Bool {
        ProcessInfo.processInfo.environment["BELLASREEF_UITEST_REPAIR"] == "1"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Pairing

    func testPairsWithARealHub() throws {
        let app = XCUIApplication()
        if repairRequested { app.launchArguments += ["-uitest-reset-pairing"] }
        app.launch()

        let tankTab = app.tabBars.buttons["Tank"]
        if tankTab.waitForExistence(timeout: 8) {
            throw XCTSkip(
                "this device is already paired, so the pairing screens cannot be reached. "
                + "Re-run with TEST_RUNNER_BELLASREEF_UITEST_REPAIR=1 to clear the "
                + "credential first (this spends a pairing window)."
            )
        }

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

        // 2. The identify card: /info before any commitment, and a name the
        //    operator can edit. Without the field every device pairs as
        //    "iPhone", because UIDevice.current.name returns the model without
        //    an entitlement this project does not declare.
        let nameField = app.textFields["client-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 15), "identify card never loaded")
        XCTAssertFalse(
            (nameField.value as? String ?? "").isEmpty,
            "the name field was not seeded, so a blank name would be sent"
        )
        attach(app, named: "identify-card")

        let pairButton = app.buttons.containing(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Pair")
        ).firstMatch
        XCTAssertTrue(pairButton.waitForExistence(timeout: 5), "no pair button on the identify card")
        pairButton.tap()

        // 3. Two legitimate endings, and both must be assertable. A hub with an
        //    open window (or no client ever) grants immediately; a hub with a
        //    live approver returns 202 and this device must SHOW ITS CODE —
        //    which is the screen that did not exist, and the reason a second
        //    device could never finish pairing.
        let code = app.staticTexts["pairing-code"]
        // One expectation with an OR, not two expectations: XCTWaiter waits for
        // ALL of its expectations, and these two endings are mutually exclusive,
        // so a pair of them can only ever time out.
        let landedEither = NSPredicate { _, _ in tankTab.exists || code.exists }
        let reachedAnEnding = expectation(for: landedEither, evaluatedWith: NSNull())
        let outcome = XCTWaiter().wait(for: [reachedAnEnding], timeout: 25)
        XCTAssertNotEqual(
            outcome, .timedOut,
            "pairing produced neither a dashboard nor a pairing code — check for a "
            + "recovery-needed state"
        )

        if code.exists {
            attach(app, named: "pairing-code")
            let digits = (code.label.filter(\.isNumber))
            XCTAssertEqual(
                digits.count, 6,
                "the waiting screen must show six digits for the operator to type — got "
                + "'\(code.label)'"
            )
            // The countdown replaces a hardcoded "five minutes" that was wrong
            // the moment the hub's expiry changed.
            XCTAssertTrue(
                app.staticTexts.containing(
                    NSPredicate(format: "label BEGINSWITH %@", "Expires in ")
                ).firstMatch.exists,
                "no expiry countdown beside the code"
            )
        } else {
            XCTAssertTrue(tankTab.exists, "paired but never reached the dashboard")
        }
    }

    // MARK: - The dashboard

    func testShowsALiveTemperature() throws {
        let app = XCUIApplication()
        app.launch()

        let tankTab = app.tabBars.buttons["Tank"]
        guard tankTab.waitForExistence(timeout: 20) else {
            throw XCTSkip(
                "not paired, so there is no dashboard to check. Run the pairing test first, "
                + "or open a window on the hub with `bellasreef pair`."
            )
        }

        // A live reading. The hero shows "—" until the first sensor frame, so
        // waiting for a digit is waiting for the stream to actually deliver.
        let hero = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+\\.[0-9]$")
        ).firstMatch
        XCTAssertTrue(
            hero.waitForExistence(timeout: 45),
            "no temperature rendered — frames are not reaching the app"
        )

        attach(app, named: "tank")

        // And the safety line reports honestly rather than optimistically.
        // Any of these is a truthful answer; what would be wrong is silence,
        // or a stale number presented as current.
        // The status line is combined into one accessibility element for
        // VoiceOver (§7.5), so its label is "Status: …" rather than the bare
        // text. Querying the raw string finds nothing — which is what the first
        // run of this assertion discovered.
        let status = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Status: ")
        ).firstMatch
        XCTAssertTrue(status.exists, "status line said nothing meaningful")

        // The sensor detail sheet: tap the reading, land on rename +
        // thresholds, with the raw id present exactly here and nowhere else.
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

    // MARK: - The approver's half

    /// System → Add a device, up to but not including approving anything.
    ///
    /// Deliberately stops short of typing a real code: approving is the one
    /// action here that changes state on the hub, and a UI test that quietly
    /// pairs a phantom client is the kind of thing that turns into a support
    /// question six months later. Reaching the screen and finding the field is
    /// what was missing — there was no screen at all.
    func testTheApproverScreenIsReachable() throws {
        let app = XCUIApplication()
        app.launch()

        let systemTab = app.tabBars.buttons["System"]
        guard systemTab.waitForExistence(timeout: 20) else {
            throw XCTSkip("not paired, so the System tab does not exist yet.")
        }
        systemTab.tap()

        XCTAssertTrue(
            app.staticTexts["Paired devices"].waitForExistence(timeout: 10),
            "no paired-devices section — revoking another device has nowhere to live"
        )

        let add = app.buttons["add-a-device"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no way to add a second device")
        add.tap()

        let field = app.textFields["claim-code-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the claim screen has no code field")
        attach(app, named: "add-a-device")

        // Six digits or nothing: the hub's pattern is ^[0-9]{6}$ and the field
        // filters on the way in, so a partial code must not be submittable.
        field.tap()
        field.typeText("12")
        XCTAssertFalse(
            app.buttons["Approve"].isEnabled,
            "a two-digit code was submittable, which earns a 422 the operator has to decode"
        )

        app.buttons["Cancel"].tap()
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
