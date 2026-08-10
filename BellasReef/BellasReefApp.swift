// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

@main
struct BellasReefApp: App {
    @State private var model = AppModel()
    @State private var preferences = Preferences()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(preferences)
                // The model needs preferences too — the primary-sensor choice
                // is read while assembling the Tank tab, not just in Settings.
                .task { model.preferences = preferences }
                // Dark is primary (design brief §2). Declared here as well as in
                // Info.plist so previews and the simulator agree with the device.
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// What the app knows about the hub it is bound to.
///
/// Deliberately small: the app is either unpaired (show the connect flow) or
/// paired (show the tabs). Anything more elaborate would be inventing product
/// the design brief has not specified.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case choosingHub
        case paired(Hub)
    }

    var phase: Phase = .choosingHub
    private(set) var client: HubClient?
    private(set) var monitor: TankMonitor?
    private(set) var catalog: DeviceCatalog?
    /// Held here so views can reach preferences through the one model they
    /// already have, rather than every sheet re-declaring an @Environment.
    var preferences: Preferences?

    /// Restore a previous pairing, if the Keychain still holds a credential.
    ///
    /// The refresh token is the durable half; the access token is minted
    /// silently on launch. That is the whole "steps 1–4 happen once per device,
    /// ever" promise from auth.md — every later launch is a token refresh and
    /// straight to the dashboard.
    func restore(lastHub: Hub?) async {
        guard let hub = lastHub else { return }
        let client = HubClient(hub: hub)
        guard await client.isPaired() else { return }
        adopt(client, hub: hub)
    }

    func adopt(_ client: HubClient, hub: Hub) {
        self.client = client
        let monitor = TankMonitor(client: client, stream: StreamClient(baseURL: hub.baseURL))
        self.monitor = monitor
        self.catalog = DeviceCatalog(client: client)
        phase = .paired(hub)
        monitor.start()
    }

    /// How many devices the hub still trusts, for the sign-out warning.
    func liveClientCount() async -> Int? {
        try? await client?.liveClientCount()
    }

    /// Sign out, revoking on the hub first.
    ///
    /// Returns an error string when the hub could not be told. The local
    /// credential is cleared either way — a sign-out that silently does nothing
    /// is worse — but the operator needs to know a stale record was left
    /// behind, because that record still counts as a live approver.
    func unpair() async -> String? {
        monitor?.stop()
        var failure: String?
        do {
            try await client?.signOut()
        } catch {
            failure = "\(error)"
        }
        client = nil
        monitor = nil
        catalog = nil
        phase = .choosingHub
        HubMemory.forget()
        return failure
    }
}

/// Remembers which hub was last paired, so a relaunch does not re-discover.
///
/// UserDefaults, not the Keychain: this is an address, not a secret. The
/// credential itself lives in the Keychain.
enum HubMemory {
    private static let key = "com.bellasreef.lastHub"
    private static let nameKey = "com.bellasreef.lastHubName"

    static func remember(_ hub: Hub) {
        UserDefaults.standard.set(hub.baseURL.absoluteString, forKey: key)
        UserDefaults.standard.set(hub.name, forKey: nameKey)
    }

    /// The name is stored alongside the address rather than derived from it.
    ///
    /// It used to be `url.host`, which was survivable while discovery produced
    /// `bellasreef.local` and became wrong the moment discovery started
    /// resolving to an address — the System tab then showed an IP under the
    /// heading "Name". A host is not a name; the hub's name comes from the hub.
    static func recall() -> Hub? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let url = URL(string: raw) else { return nil }
        let stored = UserDefaults.standard.string(forKey: nameKey)
        return Hub(name: stored ?? url.host ?? "hub", baseURL: url, discovered: false)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }
}
