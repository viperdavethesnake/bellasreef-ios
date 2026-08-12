// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Discovery → identify → pair, per auth.md §2.
struct PairingFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var discovery = HubDiscovery()
    @State private var manualAddress = ""
    @State private var selected: Hub?
    /// Drives the searching -> empty transition without a timer of its own.
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            List {
                Section("On this network") {
                    if discovery.hubs.isEmpty {
                        DiscoveryStatus(discovery: discovery, now: now)
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
            // Platform convention, and the manual recovery path. A browser
            // that has wedged is invisible from here, and the gesture people
            // already reach for is the one that fixes it.
            .refreshable { discovery.restart() }
            // A clock, so "searching" becomes "nothing here" without the model
            // owning a timer. Discovery publishes when results change; the
            // *absence* of results changes nothing, so nothing would redraw.
            .task(id: discovery.searchingSince) {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
            .onChange(of: scenePhase) { _, phase in
                // iOS tears network resources down in the background, often
                // without the browser ever reporting .failed — so nothing else
                // would notice it had stopped looking.
                if phase == .active { discovery.refreshOnForeground() }
            }
            .sheet(item: $selected) { hub in
                HubIdentifyCard(hub: hub)
            }
        }
    }

    /// The three §7.1 states this section can be in.
    ///
    /// Searching, empty and failed were one spinner before. An empty list and a
    /// dead browser looked identical, and only one of them means "type the
    /// address instead" — which is the whole reason the manual field exists.
    private struct DiscoveryStatus: View {
        let discovery: HubDiscovery
        let now: Date

        private var searchedFor: TimeInterval {
            guard let since = discovery.searchingSince else { return 0 }
            return now.timeIntervalSince(since)
        }

        var body: some View {
            switch discovery.state {
            case .failed:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Discovery is not running", systemImage: "wifi.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(Theme.attention)
                    // Named, not silent. The browser is retrying on its own, and
                    // an operator who does not know that will pull-to-refresh
                    // forever or conclude the hub is dead.
                    Text("The app could not search this network. Retrying — "
                         + "or enter the address below.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.vertical, 4)

            case .searching where searchedFor >= HubDiscovery.emptyStateAfter:
                VStack(alignment: .leading, spacing: 6) {
                    Text("No hub found on this network")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    // Bonjour genuinely does not work on guest networks, across
                    // VLANs, or over a VPN. After ten seconds the honest advice
                    // is to stop waiting.
                    Text("Bonjour does not cross guest networks, VLANs or a VPN. "
                         + "Enter the address below, or pull to search again.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.vertical, 4)

            case .searching, .idle:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(discovery.isBrowsing ? "Looking for your hub…" : "Starting…")
                        .foregroundStyle(Theme.secondaryText)
                }
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
                Text(prospect(info))
                    .font(.callout)
                    .foregroundStyle(info.approversAvailable == false && info.pairingOpen == false
                                     ? Theme.attention : Theme.secondaryText)
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

    /// What will actually happen if this button is pressed.
    ///
    /// Three states, not two. `pairing_open` is keyed on clients *ever* paired,
    /// so it stays false forever once anything has paired — including after
    /// every client is revoked. Reading only that flag produced "an
    /// already-paired device will need to approve this one" on a hub where no
    /// such device existed, and no amount of waiting would have helped.
    private func prospect(_ info: Components.Schemas.Info) -> String {
        if info.pairingOpen == true {
            return "This hub has never been paired. The first device in is trusted."
        }
        if info.approversAvailable == true {
            return "An already-paired device will need to approve this one."
        }
        return "No paired device is left to approve this one. "
            + "Open a pairing window on the hub first."
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
