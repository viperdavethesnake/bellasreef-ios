// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Create or edit one schedule (spec 2026-08-19 §iOS item 3): a read-only
/// chart preview above a points list — time-wheel + duty field rows, add,
/// swipe to delete — and Save PUTs the whole curve. Nobody drags the curve;
/// Kessil is the category norm and the research said so.
///
/// The curve is pre-validated client-side with the hub's own `validate_curve`
/// rules (≥2 points, strictly ascending unique times, duty 0–100%): the wire
/// 422 is description-only, so the only good error message is the one that
/// prevents the request.
struct ScheduleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// `nil` creates. Captured once — the editor edits a local draft and the
    /// hub's copy only moves on Save.
    let schedule: Components.Schemas.ScheduleView?

    private struct DraftPoint: Identifiable {
        let id = UUID()
        var seconds: Int
        var dutyPercentText: String

        var duty: Double? {
            guard let percent = Double(dutyPercentText), (0...100).contains(percent)
            else { return nil }
            return percent / 100
        }
    }

    @State private var name: String
    @State private var draft: [DraftPoint]
    @State private var submitting = false
    @State private var problem: String?

    init(schedule: Components.Schemas.ScheduleView?) {
        self.schedule = schedule
        _name = State(initialValue: schedule?.name ?? "")
        // A new schedule starts as an editable dawn-to-dusk template rather
        // than an empty list two mandatory adds away from valid.
        let points: [DraftPoint] = schedule.map {
            $0.points.map { point in
                DraftPoint(
                    seconds: ScheduleCurve.seconds(fromWireTime: point.at) ?? 0,
                    dutyPercentText: String(Int((point.duty * 100).rounded()))
                )
            }
        } ?? [
            DraftPoint(seconds: 8 * 3600, dutyPercentText: "0"),
            DraftPoint(seconds: 10 * 3600, dutyPercentText: "60"),
            DraftPoint(seconds: 18 * 3600, dutyPercentText: "60"),
            DraftPoint(seconds: 20 * 3600, dutyPercentText: "0"),
        ]
        _draft = State(initialValue: points)
    }

    /// The draft as a curve, when it validates — drives both the preview and
    /// the Save button.
    private var draftCurve: ScheduleCurve? {
        let sorted = draft.sorted { $0.seconds < $1.seconds }
        let points = sorted.compactMap { point -> ScheduleCurve.Point? in
            point.duty.map { ScheduleCurve.Point(seconds: point.seconds, duty: $0) }
        }
        guard points.count == draft.count else { return nil }
        return ScheduleCurve(
            points: points,
            zoneIdentifier: schedule?.zone ?? TimeZone.current.identifier
        )
    }

    private var validationText: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The schedule needs a name." }
        if draft.contains(where: { $0.duty == nil }) { return "Brightness is 0–100%." }
        let times = draft.map(\.seconds)
        if Set(times).count != times.count { return "Two points share a time." }
        if draft.count < 2 { return "A curve needs at least two points." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                if let curve = draftCurve {
                    ScheduleChart(curve: curve, nowDate: nil)
                        .frame(height: 160)
                        .listRowBackground(Color.clear)
                }
            }

            Section("Name") {
                TextField("Schedule name", text: $name)
                    .accessibilityIdentifier("schedule-name")
            }

            Section("Points") {
                ForEach($draft) { $point in
                    HStack {
                        DatePicker(
                            "Time",
                            selection: timeBinding($point),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        Spacer()
                        TextField("%", text: $point.dutyPercentText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("%")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .onDelete { offsets in
                    draft.remove(atOffsets: offsets)
                }
                Button {
                    addPoint()
                } label: {
                    Label("Add point", systemImage: "plus")
                }
            }

            if let assigned = schedule {
                assignSection(assigned)
            } else {
                Section {
                    EmptyView()
                } footer: {
                    Text("Save first, then assign lights to it.")
                }
            }

            if let validationText {
                Text(validationText)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            }
            if let problem {
                Text(problem)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            }
        }
        .scrollContentBackground(.hidden)
        .reefBackground()
        .navigationTitle(schedule == nil ? "New Schedule" : "Edit Schedule")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(submitting || validationText != nil)
                    .accessibilityIdentifier("schedule-save")
            }
            if schedule == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// DatePicker wants a Date; the draft keeps seconds-of-day. Anchored to
    /// today in the device zone — only the hour and minute survive the trip
    /// back, and the wire second is always :00.
    private func timeBinding(_ point: Binding<DraftPoint>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: point.wrappedValue.seconds / 3600,
                    minute: point.wrappedValue.seconds % 3600 / 60,
                    second: 0, of: Calendar.current.startOfDay(for: Date())
                ) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                point.wrappedValue.seconds = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60
            }
        )
    }

    /// A new point lands an hour after the latest, wrapping before midnight
    /// — a deterministic spot the operator immediately re-picks anyway.
    private func addPoint() {
        let latest = draft.map(\.seconds).max() ?? 0
        let seconds = min(latest + 3600, 86_340)
        draft.append(DraftPoint(seconds: seconds, dutyPercentText: "0"))
    }

    private func save() async {
        guard let library = model.library else { return }
        submitting = true
        defer { submitting = false }
        problem = nil
        let sorted = draft.sorted { $0.seconds < $1.seconds }
        let request = Components.Schemas.ScheduleRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            points: sorted.map {
                .init(at: ScheduleCurve.wireTime(fromSeconds: $0.seconds), duty: $0.duty ?? 0)
            },
            zone: schedule?.zone ?? TimeZone.current.identifier
        )
        do {
            let outcome: HubClient.ScheduleSaveOutcome
            if let schedule {
                outcome = try await library.update(id: schedule.id, request)
            } else {
                outcome = try await library.create(request)
            }
            switch outcome {
            case .saved:
                dismiss()
            case .nameTaken:
                problem = "A schedule with that name already exists."
            case .curveRejected:
                problem = "The hub rejected the curve."
            case .unknownSchedule:
                problem = "This schedule was deleted on another device."
            }
        } catch {
            problem = HumanError.describe(error)
        }
    }

    /// Channel multi-select (spec: "Assign = channel multi-select on the
    /// schedule"). Toggling talks to the hub immediately — assignment is not
    /// part of the curve draft, and the hub is its authority.
    @ViewBuilder
    private func assignSection(_ schedule: Components.Schemas.ScheduleView) -> some View {
        let lights = (model.catalog?.devices ?? [])
            .filter { $0.adopted == true && $0.role == "light" }
            .sorted { $0.deviceId < $1.deviceId }
        Section("Assigned lights") {
            if lights.isEmpty {
                Text("No lights adopted — adopt a PWM channel under System.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(lights, id: \.deviceId) { light in
                let current = model.library?.schedule(assignedTo: light.deviceId)
                let isThis = current?.id == schedule.id
                Button {
                    Task { await toggle(light.deviceId, schedule: schedule, currentlyThis: isThis) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(light.displayName ?? light.deviceId)
                                .foregroundStyle(Theme.primaryText)
                            if let current, !isThis {
                                Text("Now on \(current.name) — selecting moves it.")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Spacer()
                        if isThis {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(submitting)
            }
        }
    }

    private func toggle(
        _ channelId: String, schedule: Components.Schemas.ScheduleView, currentlyThis: Bool
    ) async {
        guard let library = model.library else { return }
        submitting = true
        defer { submitting = false }
        problem = nil
        do {
            if currentlyThis {
                _ = try await library.unassign(channelId: channelId)
            } else {
                switch try await library.assign(channelId: channelId, scheduleId: schedule.id) {
                case .assigned: break
                case .notCommandable:
                    problem = "That channel is observe-only — it accepts no commands."
                case .unknownSchedule:
                    problem = "This schedule was deleted on another device."
                }
            }
        } catch {
            problem = HumanError.describe(error)
        }
    }
}
