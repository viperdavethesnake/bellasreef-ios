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
        .tabBarMinimizeBehavior(.onScrollDown)

    }
}
