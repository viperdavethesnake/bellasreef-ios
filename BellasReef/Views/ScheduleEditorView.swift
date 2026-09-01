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
    }

    @State private var name: String
    @State private var draft: [DraftPoint]
    @State private var submitting = false
    @State private var problem: String?
    /// The Add-menu pick that would move a light off another schedule,
    /// held while its confirmation dialog is up.
    @State private var moving: AssignmentSection.Candidate?

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

    /// The view's `draft` in Kit's terms — the one thing `draftCurve`,
    /// `validationText` and `save()` all build from, so the rules those three
    /// used to reimplement separately now live in exactly one place
    /// (`ScheduleDraft.validate()`).
    private var scheduleDraft: ScheduleDraft {
        ScheduleDraft(
            name: name,
            points: draft.map { ScheduleDraft.DraftPoint(seconds: $0.seconds, dutyPercentText: $0.dutyPercentText) },
            zoneIdentifier: schedule?.zone ?? TimeZone.current.identifier
        )
    }

    /// The draft as a curve, when it validates — drives both the preview and
    /// the Save button. Goes through the validated wire request rather than
    /// `draft` directly, so this is provably the same curve `save()` would
    /// send.
    private var draftCurve: ScheduleCurve? {
        guard case .success(let request) = scheduleDraft.validate() else { return nil }
        let points = request.points.compactMap { point -> ScheduleCurve.Point? in
            ScheduleCurve.seconds(fromWireTime: point.at).map { ScheduleCurve.Point(seconds: $0, duty: point.duty) }
        }
        return ScheduleCurve(points: points, zoneIdentifier: request.zone ?? TimeZone.current.identifier)
    }

    private var validationText: String? {
        guard case .failure(let message) = scheduleDraft.validate() else { return nil }
        return message
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

            Section {
                // `.element.id` keeps ForEach's own diffing on the row's
                // stable UUID (unchanged); `index` is only for the
                // accessibility identifier below — the ruling was index,
                // not the fresh-UUID `DraftPoint.id`, for that identifier
                // specifically.
                ForEach(Array(draft.enumerated()), id: \.element.id) { index, _ in
                    HStack {
                        DatePicker(
                            "Time",
                            selection: timeBinding($draft[index]),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .environment(\.timeZone, TimeZone.gmt)
                        Spacer()
                        TextField("%", text: $draft[index].dutyPercentText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .accessibilityLabel("Brightness percent")
                            .accessibilityIdentifier("schedule-point-duty-\(index)")
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
                .disabled(scheduleDraft.nextFreeTime() == nil)
            } header: {
                Text("Points")
            } footer: {
                // Sub-8% points are legal on the wire and mean "off" — the
                // hub's own snap_duty rule, not a client-side restriction —
                // so this explains rather than blocks (UX review SF2).
                Text(Dimming.floorFootnote)
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
        // The ghost section below reads `model.catalog?.devices`, which is a
        // snapshot from whenever something last refreshed it — re-adding a
        // device on the System tab updates that screen but not this one, so
        // the editor kept saying "Not adopted — output resumes…" a minute
        // after the engine was already commanding the channel (rehearsal F7).
        // Refresh on entry; `refresh()` swallows its own errors, so a failed
        // fetch just leaves the snapshot as it was.
        .task {
            await model.catalog?.refresh()
        }
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
    /// the fixed UTC reference day in GMT (`ScheduleDraft.secondsOfDay(from:)`
    /// / `date(secondsOfDay:)`), which the `DatePicker`'s own
    /// `.environment(\.timeZone, TimeZone.gmt)` agrees with — only the hour
    /// and minute survive the trip back, and the wire second is always :00.
    private func timeBinding(_ point: Binding<DraftPoint>) -> Binding<Date> {
        Binding(
            get: { ScheduleDraft.date(secondsOfDay: point.wrappedValue.seconds) },
            set: { date in point.wrappedValue.seconds = ScheduleDraft.secondsOfDay(from: date) }
        )
    }

    /// A new point lands an hour after the latest, wrapping before midnight —
    /// `ScheduleDraft.nextFreeTime()`'s rule, which also finds a free minute
    /// if that spot is already taken. The Add control is disabled when it
    /// returns `nil`, so this is only ever called with a real value.
    private func addPoint() {
        guard let seconds = scheduleDraft.nextFreeTime() else { return }
        draft.append(DraftPoint(seconds: seconds, dutyPercentText: "0"))
    }

    private func save() async {
        guard let library = model.library else { return }
        guard case .success(let request) = scheduleDraft.validate() else { return }
        submitting = true
        defer { submitting = false }
        problem = nil
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

    /// The honest replacement for the old "Assigned lights" multi-select
    /// (ruled 2026-08-25, at the bench): that section listed every adopted
    /// light with a checkmark on the assigned ones, so candidates read as
    /// assignments, toggling was undiscoverable, and unassign was invisible.
    /// Now "Assigned" holds exactly what the schedule names — adopted lights
    /// and ghosts alike, absorbing the old "Still assigned" section — each
    /// with an explicit Remove, and "Add light…" is a menu of what could be
    /// added, confirming before it moves a light off another schedule.
    /// Talking to the hub stays immediate — assignment is not part of the
    /// curve draft, and the hub is its authority.
    @ViewBuilder
    private func assignSection(_ schedule: Components.Schemas.ScheduleView) -> some View {
        // `schedule` is the immutable snapshot captured at init — a
        // successful remove refreshes `model.library` but never that
        // snapshot, so a removed row would survive its own Remove button
        // until the editor is dismissed. Read the live copy instead, falling
        // back to the snapshot only if the library hasn't loaded.
        let liveAssigned = model.library?.schedules.first(where: { $0.id == schedule.id })?.assignedChannels
            ?? schedule.assignedChannels
        let devices = model.catalog?.devices ?? []
        let rows = AssignmentSection.assigned(
            channelIds: liveAssigned, devices: devices,
            devicesKnown: model.catalog?.state == .loaded
        )
        let candidates = AssignmentSection.candidates(
            for: schedule.id, schedules: model.library?.schedules ?? [schedule],
            devices: devices
        )
        Section("Assigned") {
            if rows.isEmpty {
                Text(candidates.isEmpty
                     ? "No lights adopted — adopt a PWM channel under System."
                     : "No lights assigned.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(rows, id: \.channelId) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .foregroundStyle(Theme.primaryText)
                        // Display names are not unique (ruled 2026-08-25: no
                        // enforcement), so the driver · channel identity the
                        // Devices screen has keeps same-named lights apart.
                        if let subtitle = row.subtitle {
                            Text(subtitle)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        if row.adopted == false {
                            Text("Not adopted — output resumes if this channel is adopted again.")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer()
                    Button("Remove") {
                        Task { await remove(row.channelId) }
                    }
                    .font(Theme.caption)
                    .disabled(submitting)
                    .accessibilityIdentifier("schedule-remove-\(row.channelId)")
                }
                .frame(minHeight: 44)
            }
            if !candidates.isEmpty {
                Menu {
                    ForEach(candidates, id: \.channelId) { candidate in
                        Button {
                            if candidate.currentScheduleName != nil {
                                moving = candidate
                            } else {
                                Task { await add(candidate.channelId, schedule: schedule) }
                            }
                        } label: {
                            // One line per light: the subtitle keeps
                            // same-named rows apart, and a light that would
                            // be moved says where it is now.
                            if let from = candidate.currentScheduleName {
                                Text("\(candidate.name) · \(candidate.subtitle) — on \(from)")
                            } else {
                                Text("\(candidate.name) · \(candidate.subtitle)")
                            }
                        }
                    }
                } label: {
                    Text("Add light…")
                        .frame(minHeight: 44)
                }
                .disabled(submitting)
                .accessibilityIdentifier("schedule-add-light")
            }
        }
        .confirmationDialog(
            "Move this light?",
            isPresented: Binding(
                get: { moving != nil },
                set: { if !$0 { moving = nil } }
            ),
            titleVisibility: .visible,
            presenting: moving
        ) { candidate in
            Button("Move \(candidate.name)") {
                Task { await add(candidate.channelId, schedule: schedule) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text("“\(candidate.name)” is on “\(candidate.currentScheduleName ?? "another schedule")” "
                 + "now. A light runs one schedule at a time, so it leaves "
                 + "that one and follows this one immediately.")
        }
    }

    /// Assigns one light to this schedule. The hub moves a light off its
    /// previous schedule as part of the same call — one schedule per light is
    /// its rule; the move confirmation upstream is courtesy, not mechanism.
    private func add(_ channelId: String, schedule: Components.Schemas.ScheduleView) async {
        guard let library = model.library else { return }
        submitting = true
        defer { submitting = false }
        problem = nil
        do {
            switch try await library.assign(channelId: channelId, scheduleId: schedule.id) {
            case .assigned: break
            case .notCommandable:
                problem = "That channel is observe-only — it accepts no commands."
            case .unknownSchedule:
                problem = "This schedule was deleted on another device."
            }
        } catch {
            problem = HumanError.describe(error)
        }
    }

    /// Removes one assigned channel — adopted or ghost, the same call:
    /// `library.unassign` works on non-adopted channels (backend verified).
    /// No confirm: removal drops the light toward 0, the safe direction, and
    /// adding it back is two taps.
    private func remove(_ channelId: String) async {
        guard let library = model.library else { return }
        submitting = true
        defer { submitting = false }
        problem = nil
        do {
            _ = try await library.unassign(channelId: channelId)
        } catch {
            problem = HumanError.describe(error)
        }
    }
}
