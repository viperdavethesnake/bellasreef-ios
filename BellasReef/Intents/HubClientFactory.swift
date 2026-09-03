// Bella's Reef iOS — closed source.

import BellasReefKit
import Foundation

/// One way to build a `HubClient` for the hub this device is paired to.
///
/// Extracted from `AppModel.restore(lastHub:)` (UX review D3): an app intent
/// woken by Shortcuts, Siri or a Live Activity button has no `AppModel` in
/// scope and must assemble the same thing — the remembered address plus the
/// Keychain credential — from the same two pieces, or it is a second opinion
/// on what "paired" means.
///
/// Building a second `HubClient` while the app is already running is safe:
/// the refresh token in the Keychain is not rotated by a mint
/// (`HubClient.mintFresh`), so the only cost is one extra `token.minted`
/// audit row. The alternative — reaching into the running app's model — would
/// mean a singleton that exists for one caller and is nil in exactly the case
/// the caller cares about (the app not running).
enum HubClientFactory {

    /// A client for `hub`, or nil when this device holds no credential for it.
    ///
    /// Nil rather than a throw: "not paired" is a state with its own sentence
    /// at each call site, not a transport failure.
    static func paired(with hub: Hub) async -> HubClient? {
        let client = HubClient(hub: hub)
        guard await client.isPaired() else { return nil }
        return client
    }

    /// A client for the last hub this device paired with.
    static func remembered() async -> HubClient? {
        guard let hub = HubMemory.recall() else { return nil }
        return await paired(with: hub)
    }
}
