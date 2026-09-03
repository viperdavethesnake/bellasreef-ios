// Bella's Reef iOS — closed source.

import BellasReefKit
import Foundation

/// Releasing one known hold, from outside the app's own screens.
///
/// The app half of `ReleaseHoldIntent` (UX review D2), kept here rather than
/// in `Shared/` so the widget extension never sees `BellasReefKit` or the
/// swift-openapi runtime — see that intent's own comment for why that matters
/// and how the split is made.
enum HoldRelease {

    /// End `overrideId` on the hub, then take its banner down.
    ///
    /// Releases by id rather than by light. The banner was drawn with the id
    /// of the hold it is showing, and that is the hold the operator is
    /// cancelling — looking the light's *current* hold up instead would let a
    /// tap meant for one hold end a different one that superseded it.
    ///
    /// A 404 is `.alreadyReleased`, and that is the same news: the hold is
    /// gone. The banner comes down either way.
    static func run(overrideId: String) async throws {
        guard let client = await HubClientFactory.remembered() else {
            throw IntentFailure.notPaired
        }
        do {
            _ = try await client.release(overrideId: overrideId)
        } catch {
            throw IntentFailure.hub(HumanError.describe(error))
        }
        await HoldActivityController.shared.end(overrideId: overrideId)
    }
}
