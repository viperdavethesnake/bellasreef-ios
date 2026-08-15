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

/// The four tabs from design brief §3.
///
/// History remains a placeholder this pass — declared rather than hidden, so
/// the shape of the app is visible and the brief's screen map is not quietly
/// reinterpreted later. Lighting is real as of the 2026-08-15 manual-control
/// spec (Feature 2): day curves are still out of scope (see that spec's "Out
/// of scope"), but manual holds are not a placeholder any more.
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

struct ComingSoon: View {
    let title: String
    let detail: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Text("Not built yet")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .reefBackground()
            .navigationTitle(title)
        }
    }
}
