// Bella's Reef iOS — closed source.

import XCTest

/// Captures each tab for design review.
///
/// Bench-only, like the other UI tests. It asserts almost nothing on purpose —
/// its output is the attachments, and its job is to make "show me the screens"
/// a repeatable command rather than a manual pass through the simulator.
final class ScreenshotTests: XCTestCase {

    func testCaptureEveryTab() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Tank"].waitForExistence(timeout: 30), "not paired")
        // Let the first frames land so Tank is captured populated, not loading.
        _ = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+\\.[0-9].*$")
        ).firstMatch.waitForExistence(timeout: 45)

        // Let a few samples land so Tank is captured with its trace, not with a
        // single point and no context line.
        sleep(20)

        for tab in ["Tank", "Lighting", "History", "System"] {
            app.tabBars.buttons[tab].tap()
            usleep(900_000)
            XCTContext.runActivity(named: tab.lowercased()) { activity in
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = tab.lowercased()
                shot.lifetime = .keepAlways
                activity.add(shot)
            }
        }
    }
}
