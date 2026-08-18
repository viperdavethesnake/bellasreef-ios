// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.bellasreef.app", category: "system")

struct SystemView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @State private var confirmingUnpair = false
    /// The rows, not a count. The count is derived below — fetching the list and
    /// throwing it away is why there was never a devices screen to revoke from.
    @State private var clients: [Components.Schemas.Client]?
    @State private var clientsFailed = false
    @State private var addingDevice = false
    @State private var revoking: Components.Schemas.Client?
    @State private var revokeProblem: String?
    @State private var signOutProblem: String?
    /// The hub's own name, from `/info`. Authoritative regardless of how this
    /// device found the hub — Bonjour, a typed address, or a restored pairing.
    @State private var hubName: String?
    @State private var hubNameFailed = false
    @State private var capabilities: [Components.Schemas.CapabilityView]?
    @State private var hardwareDevices: [Components.Schemas.DeviceView]?
    @State private var hardwareFailed = false
    @State private var adopting: Components.Schemas.CapabilityView?
    @State private var unadopting: Components.Schemas.DeviceView?
    @State private var forgetting: Components.Schemas.DeviceView?
    @State private var unadoptProblem: String?

    var body: some View {
        @Bindable var preferences = preferences

        NavigationStack {
            List {
                Section("Hub") {
                    LabeledContent("Name") {
                        if let hubName {
                            Text(hubName).foregroundStyle(Theme.primaryText)
                        } else if hubNameFailed {
                            // Honest rather than convenient: showing the address
                            // here is what produced "Name: 192.168.254.236".
                            Text("Unavailable").foregroundStyle(Theme.tertiaryText)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if case let .paired(hub) = model.phase {
                        LabeledContent("Address", value: hub.baseURL.absoluteString)
                    }
                }

                pairedDevices

                hardware

                Section {
                    NavigationLink {
                        AuditLogView()
                    } label: {
                        Text("Audit log")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("audit-log")
                } footer: {
                    Text("The hub's append-only record of who did what — every pairing, "
                         + "adoption and revocation it has recorded.")
                }

                Section {
                    Picker("Temperature", selection: $preferences.temperatureUnit) {
                        ForEach(TemperatureUnitPreference.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    // Inline rather than a segmented control: three options with
                    // words rather than glyphs, and it reflows instead of
                    // truncating at accessibility text sizes (§7.5). A segmented
                    // control clips "Fahrenheit" to "Fahre…" at XXL.
                    .pickerStyle(.inline)
                } header: {
                    Text("Units")
                } footer: {
                    Text(automaticExplanation)
                }

                Section {
                    // Standard iOS destructive styling, per design brief §2 as
                    // amended: control-red is the platform's word for "this
                    // deletes something", and is not the safety red that governs
                    // status and data.
                    Button("Sign out of this hub", role: .destructive) {
                        confirmingUnpair = true
                    }
                    // §7.4: nothing destructive fires on a single tap, and the
                    // row keeps a 44pt target.
                    .frame(minHeight: 44)

                    if let signOutProblem {
                        Label(signOutProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.attention)
                    }
                } footer: {
                    Text(!countKnown
                         ? "The hub could not be asked which devices are paired. Until it "
                           + "answers, treat this as the only one it still trusts."
                         : isLastDevice
                         ? "This is the only device the hub still trusts. Signing out "
                           + "revokes it, and pairing again will need hub access."
                         : "Revokes this device on the hub and forgets the credential "
                           + "here. Another paired device can approve it again later.")
                }
            }
            .scrollContentBackground(.hidden)
            .reefBackground()
            .navigationTitle("System")
            // Inline titles blurred over content that scrolled under them (UX
            // review B2). The soft edge effect is the system's answer.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .task { await loadEverything() }
            // The list is otherwise a snapshot from whenever this tab last
            // appeared, and the hub changes under it — another device pairs, a
            // client is revoked from the CLI — with nothing pushed to say so.
            .refreshable { await loadEverything() }
            .sheet(isPresented: $addingDevice) {
                AddDeviceView(onApproved: { Task { await loadClients() } })
            }
            .sheet(item: $adopting) { capability in
                AdoptDeviceSheet(capability: capability) {
                    Task { await loadHardware() }
                }
            }
            .confirmationDialog(
                "Unadopt this device?",
                isPresented: Binding(
                    get: { unadopting != nil },
                    set: { if !$0 { unadopting = nil } }
                ),
                titleVisibility: .visible,
                presenting: unadopting
            ) { device in
                Button("Unadopt \(device.displayName ?? device.deviceId)") {
                    Task { await unadopt(device) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The engine stops commanding this channel and it returns to "
                     + "its safe state. Nothing is deleted: the name, thresholds "
                     + "and history are kept, and adopting the same hardware "
                     + "again reattaches them.")
            }
            .confirmationDialog(
                "Clear this device?",
                isPresented: Binding(
                    get: { forgetting != nil },
                    set: { if !$0 { forgetting = nil } }
                ),
                titleVisibility: .visible,
                presenting: forgetting
            ) { device in
                Button("Clear \(device.displayName ?? device.deviceId)",
                       role: .destructive) {
                    Task { await forget(device) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its name and settings are deleted for good. Readings it "
                     + "already recorded stay in history. If the hardware comes "
                     + "back, adopting its channel starts a fresh device.")
            }
            // Same treatment as sign-out: nothing destructive on a single tap,
            // and the dialog names the device rather than saying "this one".
            .confirmationDialog(
                "Revoke this device?",
                isPresented: Binding(
                    get: { revoking != nil },
                    set: { if !$0 { revoking = nil } }
                ),
                titleVisibility: .visible,
                presenting: revoking
            ) { client in
                Button("Revoke \(client.name)", role: .destructive) {
                    Task { await revoke(client) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { client in
                Text("\(client.name) stops working immediately and cannot mint another "
                     + "token. If it is a device you still have, it will need pairing "
                     + "again from a device that is still trusted.")
            }
            .confirmationDialog(
                isLastDevice ? "Sign out the last device?" : "Sign out of this hub?",
                isPresented: $confirmingUnpair,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    Task { signOutProblem = await model.unpair() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Naming the exact command matters. The alternative — which is
                // what shipped, and what locked David out — is telling somebody
                // to wait for an approval that no device can give.
                Text(!countKnown
                     ? "The hub could not say whether another device is paired. If none "
                       + "is, nothing can approve this one again, and getting back in "
                       + "will need `bellasreef pair` on the hub."
                     : isLastDevice
                     ? "No other device is paired, so nothing can approve this one "
                       + "again. To get back in you will need to run `bellasreef pair` "
                       + "on the hub."
                     : "Another paired device can approve this one again later.")
            }
        }
    }

    /// Every device the hub trusts, and the two things you can do about it.
    ///
    /// `revokeClient` existed, was tested on the hub, and had no caller and
    /// nowhere to live: the app fetched this list only to reduce it to a count.
    /// A lost phone could not be revoked from the phone you still had.
    @ViewBuilder
    private var pairedDevices: some View {
        Section {
            if let clients {
                ForEach(clients, id: \.id) { client in
                    row(client)
                }
                // A refresh that fails after a successful load keeps the old
                // rows on screen — better than blanking a list the operator is
                // reading — but must say so, or a just-revoked device sits
                // there looking trusted.
                if clientsFailed {
                    Text("Could not refresh this list — it may be out of date.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.attention)
                }
            } else if clientsFailed {
                Text("Could not ask the hub which devices are paired.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                ProgressView().controlSize(.small)
            }

            Button("Add a device") { addingDevice = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("add-a-device")

            if let revokeProblem {
                Label(revokeProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            }
        } header: {
            Text("Paired devices")
        } footer: {
            Text("Revoking is immediate — the hub checks on every request, so a revoked "
                 + "device stops working on its next one rather than when its token "
                 + "expires.")
        }
    }

    @ViewBuilder
    private func row(_ client: Components.Schemas.Client) -> some View {
        let isSelf = client.id == HubMemory.recallClientId()
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).foregroundStyle(Theme.primaryText)
                Text(isSelf ? "This device" : lastSeen(client))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            // No Revoke on your own row. Signing out is the same operation with
            // a warning attached, and it already knows how to say "this is the
            // last device the hub trusts".
            //
            // And no Revoke on ANY row when this device cannot tell which row it
            // is (a pairing made before the clientId was recorded): `isSelf` is
            // then false everywhere, including on your own row, and the button
            // would offer self-revocation past the last-device warning.
            if !isSelf && HubMemory.recallClientId() != nil {
                Button("Revoke", role: .destructive) { revoking = client }
                    .buttonStyle(.borderless)
            }
        }
        .frame(minHeight: 44)
    }

    private func lastSeen(_ client: Components.Schemas.Client) -> String {
        guard let seen = client.lastSeenAt else { return "never connected" }
        return "last seen \(RelativeAge.describe(from: seen))"
    }

    /// Inventory and lifecycle only — controls live on the function tabs
    /// (design ruling 2026-08-13: System is never a junk drawer).
    @ViewBuilder
    private var hardware: some View {
        Section {
            if let hardwareDevices, let capabilities {
                let split = hardwareSections(hardwareDevices)
                ForEach(split.adopted, id: \.deviceId) { device in
                    adoptedRow(device)
                }
                let free = capabilities.filter { $0.boundTo == nil }
                if free.isEmpty && split.adopted.isEmpty && split.detached.isEmpty {
                    Text("The hub has not announced any hardware.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                if !free.isEmpty {
                    Text("Available channels")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                    ForEach(free) { capability in
                        Button { adopting = capability } label: {
                            availableRow(capability)
                        }
                        .accessibilityIdentifier("hardware-available-channel")
                    }
                }
                if !split.detached.isEmpty {
                    Text("Detached")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                    ForEach(split.detached, id: \.deviceId) { device in
                        detachedRow(device)
                    }
                }
                if hardwareFailed {
                    Text("Could not refresh this list — it may be out of date.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.attention)
                }
            } else if hardwareFailed {
                Text("Could not ask the hub what hardware it has.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                ProgressView().controlSize(.small)
            }

            if let unadoptProblem {
                Label(unadoptProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            }
        } header: {
            Text("Hardware")
        } footer: {
            Text("Adopting a channel makes it a device the engine may command. "
                 + "Controls live on the tab that uses the device; this list is "
                 + "the inventory. Channels are numbered from 1 here; boards "
                 + "print them from 0, so channel 1 is a board's 0.")
        }
    }

    @ViewBuilder
    private func adoptedRow(_ device: Components.Schemas.DeviceView) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName ?? device.deviceId)
                    .foregroundStyle(Theme.primaryText)
                Text(deviceSubtitle(device))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            // Not `.destructive`: unadopt is a reversible soft flag — name,
            // thresholds, bindings and history all survive, and the dialog says
            // so. Red is reserved for the one hard delete (Clear). UX review A5.
            Button("Unadopt") { unadopting = device }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("unadopt-\(device.deviceId)")
        }
        .frame(minHeight: 44)
    }

    /// A device the hub still remembers but nothing currently commands. The
    /// backend keeps the row on purpose (`unbind` is not a delete), so the
    /// operator gets a way to say which of the two things they actually want:
    /// reattach the same identity and history (Re-add), or delete the row for
    /// good (Clear, confirmed — see `forgetting`).
    @ViewBuilder
    private func detachedRow(_ device: Components.Schemas.DeviceView) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName ?? device.deviceId)
                    .foregroundStyle(Theme.primaryText)
                Text("released — history kept")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            Button("Re-add") { Task { await readopt(device) } }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("readopt-\(device.deviceId)")
            Button("Clear", role: .destructive) { forgetting = device }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("forget-\(device.deviceId)")
        }
        .frame(minHeight: 44)
    }

    /// Matches the available-channel rows' voice (`"channel \(capability.channel)"`)
    /// while staying compact for an already-adopted row: a numeric PWM channel
    /// reads as `ch 1`, a 1-Wire ROM (not a number) is shown bare rather than
    /// as `ch 28-000000bfe244`. The number is 1-based for the reader and
    /// 0-based on the wire — see `ChannelLabel`.
    private func deviceSubtitle(_ device: Components.Schemas.DeviceView) -> String {
        DeviceSubtitle.text(driverId: device.driverId, channel: device.channel, role: device.role)
    }

    @ViewBuilder
    private func availableRow(_ capability: Components.Schemas.CapabilityView) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(capability.source.rawValue) · channel \(ChannelLabel.humanNumber(capability.channel))")
                    .foregroundStyle(Theme.primaryText)
                Text(availableSubtitle(capability))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            Image(systemName: "plus.circle")
                .foregroundStyle(Theme.accent)
        }
        .frame(minHeight: 44)
    }

    /// The operator's only physical-identity cue before adopting a channel
    /// that will emit real output — e.g. an I2C address or a GPIO number.
    /// `detail` is a free-form, hub-declared container (generated as
    /// `OpenAPIRuntime.OpenAPIObjectContainer`, whose `.value` is
    /// `[String: (any Sendable)?]` — verified against the runtime source,
    /// not guessed). Only flat scalar values are shown; a nested array or
    /// object is skipped rather than rendered as a debug dump. Sorted by key
    /// so the same capability reads the same way on every refresh.
    private func availableSubtitle(_ capability: Components.Schemas.CapabilityView) -> String {
        let flat = capability.detail.additionalProperties.value
            .compactMap { key, value -> (String, String)? in
                switch value {
                case let value as String: return (key, value)
                case let value as Int: return (key, String(value))
                case let value as Double: return (key, String(value))
                case let value as Bool: return (key, String(value))
                default: return nil
                }
            }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: " · ")
        return flat.isEmpty ? "announced, not adopted" : "\(flat) · announced, not adopted"
    }

    /// True when this is the only client the hub still trusts — or when the
    /// list could not be fetched, because an unknown count must not produce the
    /// reassuring copy. Defaulting to "not last" is what would tell a genuinely
    /// last device that another one can let it back in.
    private var isLastDevice: Bool { (clients?.count ?? 1) <= 1 }

    /// Whether the count above is a fact or the safe assumption. The two get
    /// different words: "no other device is paired" is a claim this view must
    /// not make when what it means is "the hub did not answer".
    private var countKnown: Bool { clients != nil }

    private func loadEverything() async {
        // Three independent round trips to a Pi over WiFi; none needs
        // another's answer, so none waits for it.
        async let devices: Void = loadClients()
        async let hardware: Void = loadHardware()
        do {
            hubName = try await model.client?.info().name
            hubNameFailed = false
        } catch {
            hubNameFailed = true
        }
        await devices
        await hardware
    }

    private func loadClients() async {
        if let rows = await model.clients() {
            clients = rows
            clientsFailed = false
        } else {
            clientsFailed = true
        }
    }

    private func loadHardware() async {
        guard let client = model.client else {
            hardwareFailed = true
            return
        }
        do {
            async let caps = client.capabilities()
            async let devs = client.devices()
            capabilities = try await caps
            hardwareDevices = try await devs
            hardwareFailed = false
        } catch {
            hardwareFailed = true
        }
    }

    private func revoke(_ client: Components.Schemas.Client) async {
        revokeProblem = nil
        do {
            try await model.client?.revoke(clientId: client.id)
        } catch {
            log.error("revoke failed: \(String(describing: error))")
            revokeProblem = HumanError.describe(error)
        }
        await loadClients()
    }

    private func unadopt(_ device: Components.Schemas.DeviceView) async {
        unadoptProblem = nil
        do {
            _ = try await model.client?.unbind(deviceId: device.deviceId)
        } catch {
            log.error("unadopt failed: \(String(describing: error))")
            unadoptProblem = HumanError.describe(error)
        }
        await loadHardware()
    }

    /// Mirrors `AdoptDeviceSheet.adopt()`'s switch on `BindOutcome`
    /// (AdoptDeviceSheet.swift:157–169): a documented non-2xx is a decision
    /// the hub made, not a transport failure, so it gets its own copy through
    /// `unadoptProblem` rather than being silently discarded.
    private func readopt(_ device: Components.Schemas.DeviceView) async {
        unadoptProblem = nil
        do {
            if let outcome = try await model.client?.readopt(deviceId: device.deviceId) {
                switch outcome {
                case .readopted: break
                case .notDetached:
                    unadoptProblem = "This device is no longer detached — the list may be out of date."
                case .channelHeld:
                    unadoptProblem = "Another device claimed this channel since the list loaded."
                }
            }
        } catch {
            log.error("readopt failed: \(String(describing: error))")
            unadoptProblem = HumanError.describe(error)
        }
        await loadHardware()
    }

    private func forget(_ device: Components.Schemas.DeviceView) async {
        unadoptProblem = nil
        do {
            if let outcome = try await model.client?.forget(deviceId: device.deviceId) {
                switch outcome {
                // .unknown (404) is treated as already-cleared: forget is
                // idempotent, and the end state — no such row — is what the
                // operator asked for either way.
                case .forgotten, .unknown: break
                case .stillAdopted:
                    unadoptProblem = "This device is adopted again — unadopt it first."
                }
            }
        } catch {
            log.error("forget failed: \(String(describing: error))")
            unadoptProblem = HumanError.describe(error)
        }
        await loadHardware()
    }

    /// Says what `automatic` actually resolves to on *this* device, rather than
    /// leaving the operator to discover it by switching and watching.
    private var automaticExplanation: String {
        let resolved = TemperatureUnitPreference.automatic.resolved()
        let name = resolved == .fahrenheit ? "Fahrenheit" : "Celsius"
        return "Automatic follows your region, which here means \(name). "
            + "The hub always records Celsius; this only changes what you see."
    }
}

extension Components.Schemas.CapabilityView: @retroactive Identifiable {
    public var id: String { "\(source.rawValue):\(channel)" }
}
