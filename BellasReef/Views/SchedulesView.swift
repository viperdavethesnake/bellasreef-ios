// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// The schedule library (spec 2026-08-19 §iOS item 3): every curve on the
/// hub, create / edit / delete. Assignment lives inside the editor (channel
/// multi-select) and on the light detail (schedule picker) — this list just
/// says which lights each curve is playing on.
struct SchedulesView: View {
    @Environment(AppModel.self) private var model

    @State private var creating = false
    @State private var confirmingDelete: Components.Schemas.ScheduleView?
    @State private var problem: String?

    var body: some View {
        Group {
            if let library = model.library {
                content(library: library)
            } else {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "wifi.slash",
                    description: Text("Reopen the app, or re-pair from the System tab.")
                )
            }
        }
        .reefBackground()
        .navigationTitle("Schedules")
        .toolbar {
            Button {
                creating = true
            } label: {
                Label("New schedule", systemImage: "plus")
            }
            .accessibilityIdentifier("schedules-create")
        }
        .sheet(isPresented: $creating) {
            NavigationStack { ScheduleEditorView(schedule: nil) }
        }
    }

    @ViewBuilder
    private func content(library: ScheduleLibrary) -> some View {
        List {
            switch library.state {
            case .idle, .loading:
                Text("Loading schedules…")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 10) {
                    Label("Could not load the schedule library", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.attention)
                    Text(message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                    Button("Try again") { Task { await library.refresh() } }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }
            case .loaded:
                if library.schedules.isEmpty {
                    Text("No schedules yet. A schedule is a day curve — points of "
                         + "time and brightness — that assigned lights follow.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(library.schedules, id: \.id) { schedule in
                    NavigationLink {
                        ScheduleEditorView(schedule: schedule)
                    } label: {
                        row(schedule)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            confirmingDelete = schedule
                        }
                    }
                }
                if let problem {
                    Text(problem)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.attention)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await library.refresh() }
        .task { await library.refresh() }
        .confirmationDialog(
            "Delete this schedule?",
            isPresented: .init(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            presenting: confirmingDelete
        ) { schedule in
            Button("Delete \(schedule.name)", role: .destructive) {
                Task { await delete(schedule, library: library) }
            }
        } message: { schedule in
            Text(schedule.assignedChannels.isEmpty
                 ? "The curve is deleted for good."
                 : "It is playing on \(schedule.assignedChannels.count) light(s); the hub will refuse until it is unassigned.")
        }
    }

    private func row(_ schedule: Components.Schemas.ScheduleView) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(schedule.name)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.primaryText)
            Text("\(schedule.points.count) points · "
                 + (schedule.assignedChannels.isEmpty
                    ? "not assigned"
                    : "on \(schedule.assignedChannels.count) light(s)"))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func delete(
        _ schedule: Components.Schemas.ScheduleView, library: ScheduleLibrary
    ) async {
        problem = nil
        do {
            switch try await library.delete(id: schedule.id) {
            case .deleted, .unknown: break
            case .stillAssigned:
                problem = "\(schedule.name) is still assigned — unassign it from its lights first."
            }
        } catch {
            problem = HumanError.describe(error)
        }
    }
}
