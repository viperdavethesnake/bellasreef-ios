// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

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
            .task {
                // Two independent round trips to a Pi over WiFi; neither needs
                // the other's answer, so neither waits for it.
                async let devices: Void = loadClients()
                do {
                    hubName = try await model.client?.info().name
                } catch {
                    hubNameFailed = true
                }
                await devices
            }
            .sheet(isPresented: $addingDevice) {
                AddDeviceView(onApproved: { Task { await loadClients() } })
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

    /// True when this is the only client the hub still trusts — or when the
    /// list could not be fetched, because an unknown count must not produce the
    /// reassuring copy. Defaulting to "not last" is what would tell a genuinely
    /// last device that another one can let it back in.
    private var isLastDevice: Bool { (clients?.count ?? 1) <= 1 }

    /// Whether the count above is a fact or the safe assumption. The two get
    /// different words: "no other device is paired" is a claim this view must
    /// not make when what it means is "the hub did not answer".
    private var countKnown: Bool { clients != nil }

    private func loadClients() async {
        if let rows = await model.clients() {
            clients = rows
            clientsFailed = false
        } else {
            clientsFailed = true
        }
    }

    private func revoke(_ client: Components.Schemas.Client) async {
        revokeProblem = nil
        do {
            try await model.client?.revoke(clientId: client.id)
        } catch {
            revokeProblem = "\(error)"
        }
        await loadClients()
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
