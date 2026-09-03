// Bella's Reef iOS — closed source.

import AppIntents
import BellasReefAPI
import BellasReefKit
import Foundation

/// One adopted light on the paired hub, as the system sees it (UX review D3).
///
/// The app's core noun modelled once, so Siri, Spotlight and the Shortcuts
/// app all pick lights out of the same list the Lighting tab renders rather
/// than each growing its own idea of what a light is.
///
/// `id` is the hub's `device_id`. It is stable across renames — an operator
/// who renames "Light 1" to "Frag tank" keeps whatever shortcuts they built,
/// which a name-keyed id would break.
struct LightEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Light" }

    static let defaultQuery = LightQuery()

    let id: String
    /// The operator's name for the channel, resolved the same way
    /// `lightingCards` resolves it: the hub's `display_name`, or the raw
    /// device id when it has never been named.
    let name: String
    /// This channel's declared `max_runtime_s`, carried because nothing below
    /// this client enforces it: `create_override` accepts an over-runtime
    /// hold, and hardware-io's `_runtime_deadline` then latches the channel
    /// with no automatic path out. `holdMinutesCap` turns it into the ceiling
    /// `HoldLightIntent` refuses past, which is the same cap the Lighting
    /// tab's custom-duration field applies.
    ///
    /// Re-read on every resolution — the query always goes to the hub — so a
    /// runtime changed on the hub is honoured without rebuilding the
    /// shortcut.
    let maxRuntimeS: Double?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Where the system gets its list of lights.
///
/// `EntityStringQuery` rather than plain `EntityQuery` so the Shortcuts
/// search field can match on a typed name
/// (https://developer.apple.com/documentation/appintents/entitystringquery).
///
/// Every one of the three methods goes to the hub. There is no cache: a
/// shortcut built last week against a light that has since been unadopted
/// must fail with a sentence, not command a channel this operator no longer
/// owns.
struct LightQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [LightEntity] {
        let wanted = Set(identifiers)
        return try await lights().filter { wanted.contains($0.id) }
    }

    /// What the parameter picker shows before anything is typed. The whole
    /// list, unfiltered: a home tank has a handful of channels, not a
    /// directory that needs paging.
    func suggestedEntities() async throws -> [LightEntity] {
        try await lights()
    }

    /// Matches the device id as well as the name. A channel that has never
    /// been renamed shows its raw id as its name, and an operator who knows a
    /// channel as `pca9685-0` should find it by typing that even after
    /// someone has named it "Frag tank".
    func entities(matching string: String) async throws -> [LightEntity] {
        try await lights().filter {
            $0.name.localizedCaseInsensitiveContains(string)
                || $0.id.localizedCaseInsensitiveContains(string)
        }
    }

    /// Adopted `light`-role actuators, in the order the Lighting tab lists
    /// them.
    ///
    /// `isLight` is the kit's predicate, shared with `lightingCards` — the
    /// system's list of lights and the app's list of lights are the same list
    /// by construction, not by two filters that happen to agree today.
    private func lights() async throws -> [LightEntity] {
        guard let client = await HubClientFactory.remembered() else {
            throw IntentFailure.notPaired
        }
        do {
            return try await client.devices()
                .filter(isLight)
                .sorted { $0.deviceId < $1.deviceId }
                .map {
                    LightEntity(
                        id: $0.deviceId, name: $0.displayName ?? $0.deviceId,
                        maxRuntimeS: $0.maxRuntimeS
                    )
                }
        } catch {
            throw IntentFailure.hub(HumanError.describe(error))
        }
    }
}
