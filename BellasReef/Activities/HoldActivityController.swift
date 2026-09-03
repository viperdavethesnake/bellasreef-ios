// Bella's Reef iOS — closed source.

import ActivityKit
import BellasReefKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.bellasreef.app", category: "hold-activity")

/// The one place that talks to ActivityKit (UX review D2).
///
/// A hold has a start, a level, a deadline and a cancel, and every one of
/// those is worth having on the Lock Screen rather than behind an app launch.
/// Views and intents ask this; nothing else calls `Activity.request`, so
/// "which activity is showing which hold" has one answer instead of one per
/// caller.
///
/// `@MainActor` because it is state the UI drives and reads.
@MainActor
final class HoldActivityController {
    static let shared = HoldActivityController()

    /// ActivityKit's `Activity` is a non-final class the framework never
    /// marked `Sendable`, while every method that changes one (`update`,
    /// `end`) is a nonisolated `async` method — so holding a handle in
    /// main-actor state and awaiting one of those methods is "sending a
    /// main-actor-isolated value to a nonisolated method" under Swift 6
    /// strict concurrency, even though calling them from anywhere is
    /// ActivityKit's own design.
    ///
    /// This box is the narrow way across, and the two `nonisolated` helpers
    /// at the bottom of this file are the only things that unwrap it. The
    /// alternative — dropping the handle and re-finding the activity in
    /// `Activity.activities` on every call — trades a checked assumption for
    /// an unchecked one about when that list is populated after `request`.
    private struct ActivityHandle: @unchecked Sendable {
        let activity: Activity<HoldActivityAttributes>
    }

    /// One activity per light, keyed by `device_id`. A light can only be held
    /// one way at a time — the hub supersedes an override rather than
    /// stacking them — so two banners for one channel would be the app
    /// disagreeing with itself.
    private var handles: [String: ActivityHandle] = [:]

    /// When each activity was requested, for the grace window below.
    private var startedAt: [String: Date] = [:]

    private var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private init() {}

    /// Re-attach to activities that outlived the process.
    ///
    /// A Live Activity keeps running when the app is killed, so a relaunch
    /// finds banners on the Lock Screen this instance has no handle for.
    /// Without this, reconciliation cannot see them and they would go on
    /// counting down a hold that has since ended.
    func adoptExisting() {
        for activity in Activity<HoldActivityAttributes>.activities {
            let lightId = activity.attributes.lightId
            handles[lightId] = ActivityHandle(activity: activity)
            // Adopted, not exempt: the grace window is about how long the
            // *stream* needs to speak, not how old the hold is. At launch
            // nothing has arrived yet, so judging an adopted banner
            // immediately would end every one of them against an empty frame
            // set. (The state-frame gate in `reconcile` is the stronger half
            // of that protection; this is the belt to its braces.)
            //
            // Only for a light this instance is not already tracking: this
            // runs whenever the paired session's tabs appear, and an
            // activity started a minute ago must not have its grace window
            // silently restarted.
            if startedAt[lightId] == nil { startedAt[lightId] = Date() }
        }
    }

    /// Put this hold on the Lock Screen.
    ///
    /// Called on a granted hold, with the grant's own override id and
    /// deadline rather than on the next frame — the same reason the Lighting
    /// card shows the grant optimistically: the banner should be there when
    /// the operator looks up from the tap.
    func start(hold: LightingCard.ActiveHold, light: LightingCard) async {
        guard enabled else { return }
        // One per light: a re-hold supersedes on the hub and carries a new
        // override id, so the old banner is stale the moment this one exists.
        await endActivity(forLight: light.id)

        let attributes = HoldActivityAttributes(
            lightId: light.id,
            lightName: light.name,
            overrideId: hold.id,
            transitionLabel: hold.transition.label
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content(for: hold),
                // No push token: the hub has no APNs path and this app has no
                // cloud half (scope: one operator, private LAN). Every update
                // comes from this process, off the stream it already holds
                // open.
                pushType: nil
            )
            handles[light.id] = ActivityHandle(activity: activity)
            startedAt[light.id] = Date()
        } catch {
            // Nothing to say on screen: the hold itself succeeded, and a
            // banner that could not be raised is not a reason to tell the
            // operator their light is not held.
            log.error("live activity request failed: \(String(describing: error))")
        }
    }

    /// Follow one hold's own account of itself — the level the hub reports
    /// for it, and the deadline it reports.
    ///
    /// Matched by override id, so a frame describing a *different* hold on
    /// the same light updates nothing; that case is a supersede, and `start`
    /// is what handles it.
    func update(hold: LightingCard.ActiveHold) async {
        guard let handle = handles.values.first(
            where: { $0.activity.attributes.overrideId == hold.id }
        ) else { return }
        await Self.push(content(for: hold), to: handle)
    }

    /// Take down the banner for one hold, wherever the news came from.
    func end(overrideId: String) async {
        guard let entry = handles.first(
            where: { $0.value.activity.attributes.overrideId == overrideId }
        ) else { return }
        await dismiss(entry.value, lightId: entry.key)
    }

    /// The hub's live-override set says which banners are over (UX review
    /// D2): a hold that expired, and a hold another client released, never
    /// pass through this process, and the stream is the only thing that
    /// knows.
    ///
    /// `present` is every override id currently carried on a state frame, and
    /// `sawStateFrame` says whether any state frame has arrived at all —
    /// without it, an empty `present` means "nothing has spoken yet", not
    /// "nothing is held", and the two must not be confused. Both gates, and
    /// why they exist, are `HoldActivityReconcile.eligible`.
    func reconcile(present: Set<String>, sawStateFrame: Bool) async {
        let now = Date()
        let judged = handles.filter { lightId, _ in
            HoldActivityReconcile.eligible(
                startedAt: startedAt[lightId] ?? now, now: now, sawStateFrame: sawStateFrame
            )
        }
        let started = Set(judged.values.map { $0.activity.attributes.overrideId })
        for overrideId in HoldActivityReconcile.endedIds(started: started, present: present) {
            await end(overrideId: overrideId)
        }
    }

    // MARK: Internals

    private func endActivity(forLight lightId: String) async {
        guard let handle = handles[lightId] else { return }
        await dismiss(handle, lightId: lightId)
    }

    private func dismiss(_ handle: ActivityHandle, lightId: String) async {
        handles[lightId] = nil
        startedAt[lightId] = nil
        await Self.finish(handle)
    }

    /// `staleDate` is the hold's own deadline. Past it, ActivityKit marks the
    /// activity stale and the extension says so instead of counting down —
    /// which is the honest reading when the stream has gone quiet and nothing
    /// has arrived to end the banner properly.
    private func content(for hold: LightingCard.ActiveHold)
        -> ActivityContent<HoldActivityAttributes.ContentState>
    {
        ActivityContent(
            state: HoldActivityAttributes.ContentState(
                // The level the fixture will be at, not the one commanded:
                // the hub snaps anything under 8 % to 0 before it reaches the
                // pin, so a hold commanded at 5 % is dark and the banner says
                // 0 %. `Dimming.snappedPercent` is that rule, and it is a
                // named function because the order matters (snap the exact
                // duty, then round).
                percent: Dimming.snappedPercent(hold.duty), expiresAt: hold.expiresAt
            ),
            staleDate: hold.expiresAt
        )
    }

    // The two calls that leave the main actor. See `ActivityHandle`.

    private nonisolated static func push(
        _ content: ActivityContent<HoldActivityAttributes.ContentState>, to handle: ActivityHandle
    ) async {
        await handle.activity.update(content)
    }

    private nonisolated static func finish(_ handle: ActivityHandle) async {
        // Immediate: the hold is over, and a banner lingering on the Lock
        // Screen after the light has gone back to its schedule is reporting
        // a state the tank is not in.
        await handle.activity.end(nil, dismissalPolicy: .immediate)
    }
}
