// Bella's Reef iOS — closed source.

import Foundation

/// Which Live Activities the hub's own account of live holds says are over
/// (UX review D2).
///
/// A hold shown on the Lock Screen has three ways to end and the app starts
/// only one of them. The operator can tap Release in the app; the hold can
/// reach its deadline on the hub; another client — the iPad, a shortcut,
/// another phone — can release it. The last two never pass through this
/// process, so the only honest source for "is that hold still live" is the
/// stream: every state frame carries the channel's `override`, or carries
/// none, and the union of those ids is the hub's answer.
///
/// Pure and in the kit because nothing about ActivityKit is testable here —
/// `Activity.request` needs the real system — but this set arithmetic is
/// where the reasoning actually lives, and it is the half that can be wrong
/// in a way an operator notices (a banner counting down a hold that ended ten
/// minutes ago, or a banner that vanished while the light is still held).
public enum HoldActivityReconcile {

    /// The override ids this client has a running activity for that the hub
    /// no longer lists as live.
    ///
    /// `started` is what this process believes it is showing; `present` is
    /// every override id carried on a frame right now. Set difference, in one
    /// direction only: an id in `present` that this client never started is
    /// somebody else's hold, and D2 is a banner for the holds this operator
    /// placed here, not a mirror of the hub's whole override table.
    ///
    /// The caller decides which of its activities are eligible to be judged.
    /// A hold granted a moment ago is genuinely absent from `present` until
    /// the next frame arrives, so ending on that absence would take the
    /// banner down before it was ever seen — `HoldActivityController` holds a
    /// new activity back from this comparison until it has had time to appear.
    public static func endedIds(started: Set<String>, present: Set<String>) -> Set<String> {
        started.subtracting(present)
    }
}
