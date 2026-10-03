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
    /// Held here rather than left inside the TabView, so the selected tab
    /// survives anything above it being rebuilt.
    @State private var selection: TabID = .tank

    private enum TabID: Hashable { case tank, lighting, history, system }

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

    /// Whether there is anything to say at all. Time-independent — only the
    /// adopted-sensor count hides the strip and no clock changes that — so
    /// this needs no ticking of its own; `StatusStripView` runs the clock that
    /// keeps the *words* current.
    private var strip: StatusStripState {
        StatusStrip.state(
            monitor: model.monitor, preferred: model.preferences?.primarySensorId
        )
    }

    var body: some View {
        // The one accessory (UX review B3): connection and staleness on every
        // tab, not just Tank. Native chrome — the strip draws a glyph and a
        // line and lets the accessory bring the material.
        //
        // Switched with `isEnabled`, never installed and removed. Empty content
        // still draws its own capsule (measured on the simulator 2026-09-03),
        // so "no sensor adopted hides the strip" was first done by swapping
        // between a tab view with the accessory and one without. That swap
        // rebuilt the whole TabView, re-running every tab's `.task`, and on a
        // hub with no sensor adopted it fed itself (2026-10-02, coco): Tank's
        // `.task` refreshes the catalog, the catalog reads `.loading` and the
        // strip shows, the fetch lands with zero sensors and the strip hides,
        // the TabView rebuilds and Tank's `.task` runs again — ~13 requests a
        // second at the hub, each refresh cancelled mid-flight, so the catalog
        // never stayed `.loaded`: Tank amber "Waiting for a sensor", Lighting
        // "Loading lights…" forever. `isEnabled` (iOS 26.1, hence the floor)
        // keeps one tree for the life of the session.
        tabs.tabViewBottomAccessory(isEnabled: strip != .hidden) {
            StatusStripView(
                monitor: model.monitor,
                primarySensorId: model.preferences?.primarySensorId,
                unit: model.preferences?.temperatureUnit ?? .automatic
            )
        }
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

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Tank", systemImage: "drop.fill", value: TabID.tank) {
                TankView()
            }
            Tab("Lighting", systemImage: "lightbulb.fill", value: TabID.lighting) {
                LightingView()
            }
            Tab("History", systemImage: "chart.bar.fill", value: TabID.history) {
                HistoryTabView()
            }
            Tab("System", systemImage: "gearshape", value: TabID.system) {
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
    }
}
