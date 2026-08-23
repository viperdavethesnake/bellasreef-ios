// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// The hub's append-only record of who did what, pushed from the System tab.
///
/// v1 fetches one page (`limit: 200`) and sorts it client-side rather than
/// trusting the wire order — the operation does not document whether the hub
/// returns newest or oldest first, and getting that wrong here would read as
/// "the log is broken" rather than "the client guessed". Filtering by
/// category is client-side too, over the same page; a second query per
/// category is not worth it for 200 rows.
struct AuditLogView: View {
    @Environment(AppModel.self) private var model

    /// §7.1 states, made explicit rather than inferred from an empty array —
    /// same shape as `DeviceCatalog.Load`.
    private enum Load: Equatable {
        case loading
        case loaded([Components.Schemas.AuditEvent])
        case failed(String)
    }

    @State private var load: Load = .loading
    /// Paired-client id → name, so an actor reads as "iPhone A252" rather
    /// than its UUID (UX review A8). Best effort: an unreachable list leaves
    /// the short id, never blocks the log.
    @State private var clientNames: [String: String] = [:]
    /// `nil` reads as "All" — the toolbar menu's default, and the one choice
    /// that needs no match against a fetched category.
    @State private var selectedCategory: String?

    var body: some View {
        List {
            Section {
                content
            } footer: {
                Text("Most recent 200 events.")
            }
        }
        .scrollContentBackground(.hidden)
        .reefBackground()
        .navigationTitle("Audit log")
        .task { await loadAudit() }
        .refreshable { await loadAudit() }
        .toolbar {
            // The menu is the only way to clear a filter, so it must survive
            // a refresh that comes back empty while `selectedCategory` is
            // still set — otherwise "No events in X" ships with no control
            // to get back to "All".
            if case let .loaded(events) = load, !events.isEmpty || selectedCategory != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    categoryMenu(events)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            ProgressView().controlSize(.small)
        case let .loaded(events):
            let filtered = filtered(events)
            if filtered.isEmpty {
                // Names which emptiness this is: a genuinely empty log reads
                // differently from a filter that no longer matches anything
                // in the current page (e.g. a low-frequency category aged
                // out of the newest 200 on refresh). Without this, both look
                // identical to "No audit events" — indistinguishable from
                // data loss.
                Text(selectedCategory.map { "No events in \($0)" } ?? "No audit events")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                ForEach(filtered, id: \.messageId) { event in
                    row(event)
                }
            }
        case let .failed(message):
            // Amber, never red: a failed fetch is not a safety event.
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.caption)
                .foregroundStyle(Theme.attention)
            Button("Retry") { Task { await loadAudit() } }
        }
    }

    @ViewBuilder
    private func row(_ event: Components.Schemas.AuditEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.category)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.surfaceRaised))
            VStack(alignment: .leading, spacing: 2) {
                // Which device, who, when — in that order (UX review A8). The
                // device comes from device_id or the payload's target; the
                // actor is a client's name when it is a client; the time is a
                // clock time with the age beside it.
                let payload = event.event.additionalProperties.value
                let subject = AuditRow.subjectId(deviceId: event.deviceId, payload: payload)
                Text(AuditPhrase.title(
                    action: event.action,
                    deviceName: subject.map { model.catalog?.name(for: $0) ?? $0 } ?? AuditRow.subjectName(payload: payload),
                    reason: payload["reason"] as? String))
                    .foregroundStyle(Theme.primaryText)
                Text("\(AuditRow.actorName(event.actor, clients: clientNames)) · "
                     + AuditRow.when(event.occurredAt))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func categoryMenu(_ events: [Components.Schemas.AuditEvent]) -> some View {
        Menu {
            Button {
                selectedCategory = nil
            } label: {
                if selectedCategory == nil {
                    Label("All", systemImage: "checkmark")
                } else {
                    Text("All")
                }
            }
            ForEach(categories(from: events), id: \.self) { category in
                Button {
                    selectedCategory = category
                } label: {
                    if selectedCategory == category {
                        Label(category, systemImage: "checkmark")
                    } else {
                        Text(category)
                    }
                }
            }
        } label: {
            Label("Filter by category", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private func categories(from events: [Components.Schemas.AuditEvent]) -> [String] {
        Array(Set(events.map(\.category))).sorted()
    }

    private func filtered(
        _ events: [Components.Schemas.AuditEvent]
    ) -> [Components.Schemas.AuditEvent] {
        guard let selectedCategory else { return events }
        return events.filter { $0.category == selectedCategory }
    }

    private func loadAudit() async {
        guard let client = model.client else {
            load = .failed("Not connected to a hub")
            return
        }
        load = .loading
        do {
            let events = try await client.audit(limit: 200)
                .sorted { $0.occurredAt > $1.occurredAt }
            load = .loaded(events)
        } catch {
            load = .failed(HumanError.describe(error))
        }
        // Names for actors, after the log itself: a failure here costs
        // names, not the record.
        if let clients = try? await client.clients() {
            clientNames = Dictionary(uniqueKeysWithValues: clients.map { ($0.id, $0.name) })
        }
    }
}
