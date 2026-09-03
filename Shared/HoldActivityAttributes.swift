// Bella's Reef iOS — closed source.

import ActivityKit
import Foundation

/// The Live Activity for one manual hold (UX review D2).
///
/// Compiled into BOTH the app and `BellasReefActivity` — the app requests and
/// ends activities, the extension renders them, and ActivityKit encodes this
/// type across that process boundary, so the two have to be reading the same
/// declaration rather than two that agree today.
///
/// It is a file shared by two targets and not a kit type on purpose. Putting
/// it in `BellasReefKit` would make the widget extension link `BellasReefAPI`
/// and the whole swift-openapi runtime to draw a countdown, which is exactly
/// the dependency a Live Activity's memory budget should not be carrying.
/// Nothing here needs the hub client; it needs four strings and a date.
///
/// The split between the two halves is the ActivityKit rule: static
/// attributes are fixed for the life of the activity, `ContentState` is what
/// an update may change. `overrideId` is static because it identifies *this*
/// hold — the hub issues a new id when a hold is superseded, so a re-hold is
/// a new activity (the old one is ended first), not an update to this one.
struct HoldActivityAttributes: ActivityAttributes {

    /// What can change while one hold is live: the level the hub reports for
    /// it, and its deadline.
    ///
    /// `percent` is whole percent, and it is the level the *fixture* is at,
    /// not the level that was commanded: the app builds it with
    /// `Dimming.snappedPercent`, which applies the hub's 8 % floor before
    /// rounding, so a hold commanded at 5 % arrives here as 0. A banner
    /// reading "5%" beside a dark fixture is the same lie the Lighting tab
    /// was fixed for.
    struct ContentState: Codable, Hashable {
        var percent: Int
        var expiresAt: Date
    }

    /// The hub's `device_id`. Stable across renames, and the key the app
    /// holds one activity per.
    let lightId: String
    /// The operator's name for the channel, resolved the way `lightingCards`
    /// resolves it. Captured at start: a rename mid-hold is not worth an
    /// activity update.
    let lightName: String
    /// The hold this banner is for — what its Release button ends.
    let overrideId: String
    /// "Snap" or "Ramp", already worded (`HubClient.HoldTransition.label`).
    /// A string rather than the kit enum, because the enum lives in
    /// `BellasReefKit` and this file may not import it.
    let transitionLabel: String
}
