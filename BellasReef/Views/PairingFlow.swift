// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Discovery → identify → pair, per auth.md §2.
struct PairingFlow: View {
    @Environment(AppModel.self) private var model
    @State private var discovery = HubDiscovery()
    @State private var manualAddress = ""
    @State private var selected: Hub?

    var body: some View {
        NavigationStack {
            List {
                Section("On this network") {
                    if discovery.hubs.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(discovery.isBrowsing ? "Looking for your hub…" : "Starting…")
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    ForEach(discovery.hubs) { hub in
                        Button { selected = hub } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hub.name).foregroundStyle(Theme.primaryText)
                                    Text(hub.baseURL.absoluteString)
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                    }
                }

                // Bonjour fails on guest networks, across VLANs, and over a
                // VPN. A controller you cannot reach because discovery is fussy
                // is not much of a controller.
                Section("By address") {
                    TextField("bellasreef.local or 192.168.1.20", text: $manualAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(connectManually)
                    Button("Connect", action: connectManually)
                        .disabled(Hub.manual(manualAddress) == nil)
                }
            }
            .scrollContentBackground(.hidden)
            .reefBackground()
            .navigationTitle("Find your hub")
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
            .sheet(item: $selected) { hub in
                HubIdentifyCard(hub: hub)
            }
        }
    }

    private func connectManually() {
        guard let hub = Hub.manual(manualAddress) else { return }
        selected = hub
    }
}

/// `/info` before any commitment — the connect screen from auth.md step 2.
struct HubIdentifyCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let hub: Hub

    @State private var info: Components.Schemas.Info?
    @State private var problem: String?
    @State private var pairing = false
    @State private var pending: PendingPairing?
    @State private var recoveryNeeded = false

    private var clientName: String { UIDevice.current.name }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let info {
                    identity(info)
                    action(info)
                } else if let problem {
                    ContentUnavailableView(
                        "Cannot reach that hub",
                        systemImage: "wifi.exclamationmark",
                        description: Text(problem)
                    )
                } else {
                    ProgressView("Contacting hub…")
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
            .reefBackground()
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await identify() }
    }

    @ViewBuilder
    private func identity(_ info: Components.Schemas.Info) -> some View {
        VStack(spacing: 8) {
            Text(info.name).font(.title.weight(.semibold))
            Text(hub.baseURL.host ?? "").foregroundStyle(Theme.secondaryText)
            Text("API \(info.apiVersion) · contracts \(info.contractsVersion)")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private func action(_ info: Components.Schemas.Info) -> some View {
        if recoveryNeeded {
            // Verbatim from auth.md: the operator needs the exact command, and
            // paraphrasing a recovery instruction is how people end up stuck.
            VStack(spacing: 12) {
                Label("Nobody can approve this device", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.attention)
                Text("run `bellasreef pair` on the hub")
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .background(Theme.surfaceRaised, in: .rect(cornerRadius: 8))
                Text("Every paired device has been revoked, so there is no one to "
                     + "approve a new one. Open a recovery window on the hub, then "
                     + "try again.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        } else if let pending {
            PendingApproval(pending: pending, hub: hub)
        } else {
            VStack(spacing: 10) {
                Text(info.pairingOpen
                     ? "This hub has never been paired. The first device in is trusted."
                     : "An already-paired device will need to approve this one.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await pair() }
                } label: {
                    if pairing { ProgressView() } else { Text("Pair \(clientName)") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pairing)
            }
        }

        if let problem {
            Text(problem).font(Theme.caption).foregroundStyle(Theme.attention)
        }
    }

    private func identify() async {
        do {
            info = try await HubClient(hub: hub).info()
        } catch {
            problem = "\(error)"
        }
    }

    private func pair() async {
        pairing = true
        defer { pairing = false }

        let client = HubClient(hub: hub)
        do {
            switch try await client.pair(clientName: clientName) {
            case let .granted(refreshToken, _):
                try await client.store(refreshToken: refreshToken)
                HubMemory.remember(hub)
                model.adopt(client, hub: hub)
                dismiss()
            case let .pending(requestId, pollAfter):
                pending = PendingPairing(requestId: requestId, pollAfter: pollAfter)
            case .needsRecoveryCLI:
                recoveryNeeded = true
            }
        } catch {
            problem = "\(error)"
        }
    }
}

struct PendingPairing: Equatable {
    let requestId: String
    let pollAfter: Int
}

/// The 202 path: waiting for someone to tap Approve on a paired device.
struct PendingApproval: View {
    let pending: PendingPairing
    let hub: Hub

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Label("Waiting for approval", systemImage: "person.badge.clock")
                .foregroundStyle(Theme.attention)
            Text("Open Bella's Reef on a device that is already paired and "
                 + "approve “\(UIDevice.current.name)”.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Text("This request expires in five minutes.")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 24)
    }
}
