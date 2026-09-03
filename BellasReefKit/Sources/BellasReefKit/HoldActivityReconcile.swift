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
    /// Which activities are eligible to be judged this way is `eligible`'s
    /// question, not this one's — `started` is expected to have been filtered
    /// already.
    public static func endedIds(started: Set<String>, present: Set<String>) -> Set<String> {
        started.subtracting(present)
    }

    /// How long an activity is held back from `endedIds` after this client
    /// starts showing it.
    ///
    /// A hold is granted over REST and only *then* published as a state
    /// frame, so for a beat the hub's live-override set genuinely does not
    /// contain an id the banner is already showing. Thirty seconds is well
    /// past the observed frame latency (the engine publishes on the
    /// command's own tick, and the hub replays each actuator's last state on
    /// connect) and well short of the shortest hold this app will place, one
    /// minute.
    public static let reconcileGrace: TimeInterval = 30

    /// May this activity be compared against the frames yet?
    ///
    /// Two gates, and both of them exist because ending a banner for a hold
    /// that is still live is the worst thing this feature can do: the
    /// operator's tank is held at a level and the phone says it is not.
    ///
    /// **`sawStateFrame`** — has any `.state` frame been applied at all. The
    /// override ids come from state frames, so before the first one arrives
    /// the "live holds" set is empty for want of information, not because
    /// nothing is held. The stream also emits `.ready`, `.sensor` and
    /// `.alert` frames, and a caller watching "did a frame arrive" rather
    /// than "did an actuator speak" would reconcile against that empty set
    /// on the very first `.ready`. On a socket slower to come up than
    /// `grace`, that alone would end every banner adopted at launch.
    ///
    /// **`grace`** — has this activity been showing long enough for the frame
    /// that should carry it to have been published. See `reconcileGrace`.
    ///
    /// The cost of both gates is that a hold released elsewhere in the first
    /// thirty seconds keeps its banner a little longer. The cost of not
    /// having them is a banner that never appears, or one that disappears
    /// while the light is held.
    public static func eligible(
        startedAt: Date, now: Date, sawStateFrame: Bool,
        grace: TimeInterval = reconcileGrace
    ) -> Bool {
        guard sawStateFrame else { return false }
        return now.timeIntervalSince(startedAt) >= grace
    }
}
