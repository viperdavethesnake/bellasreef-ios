// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

@main
struct BellasReefApp: App {
    @State private var model = AppModel()
    @State private var preferences = Preferences()

    init() {
        #if DEBUG
        // A Keychain credential survives a reinstall, so a UI test on a device
        // that has ever paired can never reach the pairing screens — which is
        // exactly how the pairing assertions became the ones least likely to
        // run. This is the only way to put the app back in its first-launch
        // state from outside the process.
        //
        // Debug only: the flag does not exist in a shipped build, so nothing a
        // release binary can be handed will clear a working pairing.
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset-pairing") {
            try? TokenStore().clear()
            HubMemory.forget()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(preferences)
                // The model needs preferences too — the primary-sensor choice
                // is read while assembling the Tank tab, not just in Settings.
                .task { model.preferences = preferences }
                // No .preferredColorScheme: the app follows the system
                // appearance (UX-1). Dark stays primary by design intent —
                // Theme resolves an unspecified trait to the dark palette —
                // not by pin.
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
    private(set) var library: ScheduleLibrary?
    /// Why the app is back on the pairing screen, when it did not get there by
    /// the operator asking. Cleared once a new pairing lands.
    var notice: String?
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
        // Registered from a Task because HubClient is an actor and this method
        // is not async; the handoff completes before any REST call could mint
        // a token. Both halves are wired to the same landing: the monitor hears
        // a rejection on stream reconnect, the client hears the one that
        // actually happens on a revoked device — a REST call forcing a mint.
        Task {
            await client.notifyCredentialRejected { [weak self] in
                Task { @MainActor in self?.credentialRejected() }
            }
        }
        // A previous monitor (a rediscovery re-adopting at a new address)
        // must stop retrying the old one, or two loops run for one hub.
        self.monitor?.stop()
        let monitor = TankMonitor(client: client, stream: StreamClient(baseURL: hub.baseURL))
        monitor.onCredentialRejected = { [weak self] in self?.credentialRejected() }
        monitor.onUnreachable = { [weak self] in await self?.rediscover() }
        self.monitor = monitor
        let catalog = DeviceCatalog(client: client)
        self.catalog = catalog
        self.library = ScheduleLibrary(client: client)
        // Staleness follows each probe's declared cadence (UX review A3); the
        // catalog is where the cadence lives, the monitor is what judges age.
        monitor.cadenceOf = { [weak catalog] id in catalog?.device(id)?.pollIntervalS }
        // "Waiting for a sensor" only when a sensor is adopted and unheard;
        // zero adopted sensors is a configuration, not a fault (rehearsal F3).
        // Detached rows don't count — a released probe is not expected to report.
        monitor.adoptedSensorCount = { [weak catalog] in
            guard let catalog, catalog.state == .loaded else { return nil }
            return catalog.sensors.filter { $0.adopted == true }.count
        }
        notice = nil
        phase = .paired(hub)
        monitor.start()
    }

    /// When the last rediscovery ran, so a hub that is simply off for the
    /// evening is browsed for once a minute, not once per backoff tick.
    private var lastRediscovery: Date = .distantPast

    /// The stored address stopped answering: browse for the hub and follow it
    /// if it has moved (UX review B7). The address the app keeps is the one
    /// discovery resolved to — an IP, on purpose — and the hub is on DHCP, so
    /// a lease change used to mean a dead app until the operator re-paired.
    /// The pairing credential is keyed to this device, not the address, so
    /// following the hub keeps the pairing.
    ///
    /// Conservative on purpose: one hub at a new address is followed; among
    /// several, only one whose Bonjour name is ours; otherwise stay — the
    /// monitor keeps retrying the old address, and the pairing screen is a
    /// tap away for the operator to point it somewhere by hand.
    func rediscover() async {
        guard case let .paired(hub) = phase else { return }
        guard Date().timeIntervalSince(lastRediscovery) > 60 else { return }
        lastRediscovery = Date()
        let found = await HubDiscovery.browse(for: 5)
        guard case .paired = phase,  // still paired after the wait
              let moved = HubRediscovery.choose(candidates: found, current: hub)
        else { return }
        // Keep the name the hub told us; the Bonjour instance name is a
        // label for the row on the pairing screen, not the hub's own name.
        let followed = Hub(name: hub.name, baseURL: moved.baseURL, discovered: true)
        HubMemory.remember(followed, clientId: HubMemory.recallClientId())
        adopt(HubClient(hub: followed), hub: followed)
    }

    /// The hub refused this device's credential: revoked, or the hub was
    /// rebuilt underneath it.
    ///
    /// Land on the pairing screen with a sentence saying why. The previous
    /// behaviour left `phase` at `.paired` with a dead reconnect loop, so the
    /// Tank tab froze, said nothing, and offered nothing — and pairing again is
    /// genuinely the correct next move, which is the one thing the operator
    /// could not reach.
    func credentialRejected() {
        guard case .paired = phase else { return }
        monitor?.stop()
        let outgoing = client
        client = nil
        monitor = nil
        catalog = nil
        library = nil
        phase = .choosingHub
        notice = "The hub no longer accepts this device — it was revoked, or the hub was "
            + "rebuilt. Pair again to get back in."
        // The hub is still remembered so the operator can re-pair with one tap;
        // only the dead credential goes.
        Task { try? await outgoing?.forget() }
    }

    /// The devices the hub still trusts. `nil` when it could not be asked.
    func clients() async -> [Components.Schemas.Client]? {
        try? await client?.clients()
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
        library = nil
        phase = .choosingHub
        notice = nil
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
    private static let clientKey = "com.bellasreef.clientId"

    /// `clientId` is the row the hub created for *this* device.
    ///
    /// Kept so the paired-devices list can say "This device" and withhold a
    /// Revoke button from it. `GET /clients` does not mark which row is the
    /// caller, and a list of similar names each with a Revoke button beside it
    /// is a way to sign yourself out while believing you are removing a lost
    /// phone. Sign-out already exists, with its own last-device warning.
    static func remember(_ hub: Hub, clientId: String? = nil) {
        UserDefaults.standard.set(hub.baseURL.absoluteString, forKey: key)
        UserDefaults.standard.set(hub.name, forKey: nameKey)
        if let clientId { UserDefaults.standard.set(clientId, forKey: clientKey) }
    }

    /// Nil for a pairing made before this was recorded. The list then shows no
    /// "This device" row rather than guessing at one — degrading honestly beats
    /// labelling the wrong phone.
    static func recallClientId() -> String? {
        UserDefaults.standard.string(forKey: clientKey)
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
        UserDefaults.standard.removeObject(forKey: clientKey)
    }
}
