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

    }
}
