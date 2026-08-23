// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// One light's day (spec 2026-08-19 §iOS item 2): the full curve with a now
/// line, the schedule's name, the next transition — and the schedule picker,
/// the light-side mirror of the editor's channel multi-select. Resolved live
/// from the model by id, not from a card snapshot frozen at tap time: the
/// wire keeps moving while this screen is up.
struct LightDetailView: View {
    @Environment(AppModel.self) private var model

    let cardId: String

    @State private var submitting = false
    @State private var problem: String?

    /// The same merge the Lighting tab renders from — one function, so the
    /// two screens can never disagree about what is assigned.
    private var card: LightingCard? {
        guard let monitor = model.monitor, let catalog = model.catalog else { return nil }
        return lightingCards(
            devices: catalog.devices, frames: monitor.channels,
            schedules: model.library?.schedules ?? []
        ).first { $0.id == cardId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let card {
                    if let schedule = card.schedule {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(alignment: .leading, spacing: 8) {
                                ScheduleChart(curve: schedule.curve, nowDate: context.date)
                                    .frame(height: 200)
                                Text(schedule.name)
                                    .font(Theme.sectionTitle)
                                    .foregroundStyle(Theme.primaryText)
                                Text(nextTransitionText(schedule.curve, now: context.date))
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    } else {
                        Text("No schedule — resting is off.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    pickerSection(card)
                    if let problem {
                        Text(problem)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.attention)
                    }
                } else {
                    ContentUnavailableView(
                        "Light not found",
                        systemImage: "lightbulb.slash",
                        description: Text("It may have been unadopted on another device.")
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .reefBackground()
        .navigationTitle(card?.name ?? cardId)
        .task { await model.library?.refresh() }
    }

    /// "35% at 19:00" — the next anchor the curve reaches, in the
    /// schedule's own zone (the point's time is already local to it).
    private func nextTransitionText(_ curve: ScheduleCurve, now: Date) -> String {
        let next = curve.nextPoint(after: now)
        let time = ScheduleCurve.wireTime(fromSeconds: next.seconds).prefix(5)
        return "\(Int((next.duty * 100).rounded()))% at \(time)"
    }

    @ViewBuilder
    private func pickerSection(_ card: LightingCard) -> some View {
        if let library = model.library {
            VStack(alignment: .leading, spacing: 8) {
                Text("Schedule")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                Picker("Schedule", selection: pickerBinding(card, library: library)) {
                    Text("None").tag(String?.none)
                    ForEach(library.schedules, id: \.id) { schedule in
                        Text(schedule.name).tag(String?.some(schedule.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(submitting)
                .accessibilityIdentifier("light-schedule-picker")
            }
        }
    }

    private func pickerBinding(
        _ card: LightingCard, library: ScheduleLibrary
    ) -> Binding<String?> {
        Binding(
            get: { card.schedule?.id },
            set: { chosen in
                Task { await repoint(card, to: chosen, library: library) }
            }
        )
    }

    private func repoint(
        _ card: LightingCard, to scheduleId: String?, library: ScheduleLibrary
    ) async {
        submitting = true
        defer { submitting = false }
        problem = nil
        do {
            if let scheduleId {
                switch try await library.assign(channelId: card.id, scheduleId: scheduleId) {
                case .assigned: break
                case .notCommandable:
                    problem = "This channel is observe-only — it accepts no commands."
                case .unknownSchedule:
                    problem = "That schedule was deleted on another device."
                }
            } else {
                _ = try await library.unassign(channelId: card.id)
            }
        } catch {
            problem = HumanError.describe(error)
        }
    }
}
