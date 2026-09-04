// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation

/// Where Identify (C4) waits for proof that hardware-io rebuilt a channel.
///
/// Adopting restarts hardware-io. The last thing its rebuild does is publish
/// one startup `ActuatorState` per registered actuator, so a state frame for
/// the new device id proves the channel was built, opened and registered,
/// not merely that a process came back. A protocol rather than `TankMonitor`
/// itself so the flow's tests hand it canned frames without a socket.
@MainActor
public protocol StateFrameSource: AnyObject {
    /// The frame currently held for `deviceId`, if any. Its `emittedAt` is
    /// the floor a fresh frame must clear: BR_STATE is retained last-value
    /// and the hub replays it on connect, so a re-adopted channel can show a
    /// frame from its previous life.
    func heldFrame(for deviceId: String) -> Components.Schemas.StateFrame?

    /// The first frame for `deviceId` whose `payload.emittedAt` is strictly
    /// newer than `floor` (any frame when `floor` is nil), or nil once
    /// `timeout` passes. A held frame that already clears the floor resolves
    /// at once. Both timestamps come from the hub: one clock.
    func nextFrame(
        for deviceId: String, newerThan floor: Date?, timeout: Duration
    ) async -> Components.Schemas.StateFrame?
}
