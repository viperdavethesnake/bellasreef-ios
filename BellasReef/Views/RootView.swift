// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .choosingHub:
                PairingFlow()
            case .paired:
                MainTabs()
            }
        }
        .task { await model.restore(lastHub: HubMemory.recall()) }
    }
}

/// The four tabs from design brief §3. All four are live: Tank, Lighting
/// (manual holds, since the 2026-08-15 spec Feature 2 — day curves are still
/// out of scope, see that spec's "Out of scope"), History, System.
struct MainTabs: View {
    @Environment(AppModel.self) private var model

    /// Every hold the hub is reporting right now, off the same frames the
    /// Tank and Lighting tabs already render from.
    ///
    /// Lives here rather than on the Lighting tab because a Lock Screen
    /// banner outlives the screen that started it: the operator holds a
    /// light, switches to Tank, and locks the phone. The two endings this
    /// process never performs — a hold reaching its deadline, and a hold
    /// released from another client — arrive as frames, and this is the
    /// highest place inside the paired session where every frame is visible.
    private var liveOverrideIds: Set<String> {
        guard let monitor = model.monitor else { return [] }
        return Set(monitor.channels.values.compactMap { $0.override?.id })
    }

    /// Has any actuator spoken yet on this connection?
    ///
    /// `channels` is written only by a `.state` frame, so an empty one means
    /// no actuator has reported — which is not the same as "no light is
    /// held", and `liveOverrideIds` cannot tell the two apart on its own.
    /// The distinction matters because the stream also carries `.ready`,
    /// `.sensor` and `.alert` frames: reconciling on frame arrival alone
    /// would judge every banner against an empty set on the first `.ready`.
    ///
    /// Chosen over "`connection` became `.live`" because `.ready` sets that
    /// too, before any actuator state has arrived — it is the same gap one
    /// step earlier. This asks the question the reconciliation actually
    /// depends on: have the frames that carry override ids started arriving.
    private var sawStateFrame: Bool {
        !(model.monitor?.channels.isEmpty ?? true)
    }

    var body: some View {
        TabView {
            Tab("Tank", systemImage: "drop.fill") {
                TankView()
            }
            Tab("Lighting", systemImage: "lightbulb.fill") {
                LightingView()
            }
            Tab("History", systemImage: "chart.bar.fill") {
                HistoryTabView()
            }
            Tab("System", systemImage: "gearshape") {
                SystemView()
            }
        }
        // Glass belongs to the navigation layer only. Content stays solid —
        // a temperature reading never shimmers (design brief §1).
        //
        // .tabBarMinimizeBehavior(.onScrollDown) is deliberately ABSENT. It
        // installs a scroll observation on every List that feeds the tab
        // bar's minimize/expand appearance, and on iOS 26 that observation
        // closes a layout feedback loop during NavigationStack pops:
        // pop transition -> forced layout -> safe-area insets set on the
        // leaf's scroll view -> automatic content-offset adjustment ->
        // observed as a scroll -> tab bar appearance update -> overlay
        // insets change -> safe-area update -> repeat, forever, inside one
        // CA commit. Main thread pins at 100 % and every later push/pop is
        // dead. Intermittent (needs the scroll offset near a tab-bar state
        // boundary at pop time), reproduced three times on 2026-08-23 and
        // pinned by two identical stack samples. Same disease as the
        // 2026-08-18 safeAreaInset loop (SystemView), one layer deeper —
        // that time our inset was the loop's second participant; this time
        // it is the minimize observation itself, which is Apple's code, so
        // the only lever is not to opt in. Re-adding this modifier means
        // re-testing System-tab leaf pops, scrolled, on real iOS 26.

        // A Live Activity survives the app being killed, so a relaunch finds
        // banners this process has no handle for. Re-attach before the first
        // reconcile, or they would sit there counting down a hold that ended.
        .task { HoldActivityController.shared.adoptExisting() }
        // Every frame, not only the ones that change the live-hold set. The
        // case that most needs reconciling is a set that never changes: the
        // app relaunches, adopts a banner for a hold that ended while it was
        // closed, and no frame ever carries that id — so "the set changed"
        // is an edge that would never fire. The work is a set subtraction
        // over a handful of ids.
        .onChange(of: model.monitor?.lastFrameAt) { _, _ in
            let present = liveOverrideIds
            let sawState = sawStateFrame
            Task {
                await HoldActivityController.shared.reconcile(
                    present: present, sawStateFrame: sawState
                )
            }
        }
    }
}
