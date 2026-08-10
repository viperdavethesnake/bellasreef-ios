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
/// Lighting and History are placeholders this pass — declared rather than
/// hidden, so the shape of the app is visible and the brief's screen map is
/// not quietly reinterpreted later.
struct MainTabs: View {
    var body: some View {
        TabView {
            Tab("Tank", systemImage: "thermometer.medium") {
                TankView()
            }
            Tab("Lighting", systemImage: "lightbulb.fill") {
                ComingSoon(
                    title: "Lighting",
                    detail: "Day curves per channel, drag-to-edit control points, "
                          + "and manual override with its auto-revert timer."
                )
            }
            Tab("History", systemImage: "chart.bar.fill") {
                ComingSoon(
                    title: "History",
                    detail: "Temperature and per-channel duty from the hub's "
                          + "time-series store."
                )
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
