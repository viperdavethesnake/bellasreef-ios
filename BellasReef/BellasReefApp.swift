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
        phase = .paired(hub)
        monitor.start()
    }

    func unpair() async {
        monitor?.stop()
        try? await client?.forget()
        client = nil
        monitor = nil
        phase = .choosingHub
        HubMemory.forget()
    }
}

/// Remembers which hub was last paired, so a relaunch does not re-discover.
///
/// UserDefaults, not the Keychain: this is an address, not a secret. The
/// credential itself lives in the Keychain.
enum HubMemory {
    private static let key = "com.bellasreef.lastHub"

    static func remember(_ hub: Hub) {
        UserDefaults.standard.set(hub.baseURL.absoluteString, forKey: key)
    }

    static func recall() -> Hub? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let url = URL(string: raw) else { return nil }
        return Hub(name: url.host ?? "hub", baseURL: url, discovered: false)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
