// Bella's Reef iOS — closed source.

import BellasReefAPI

/// Split the hardware inventory on `adopted`.
///
/// Ruled 2026-08-15, from a walkthrough finding: after unadopting a device
/// the row stayed listed as adopted, and a second unadopt hit a 404 on the
/// hub — the backend keeps the row (history survives unadopt) but the app
/// had nowhere to put it except the adopted list. `DeviceView.adopted` now
/// says which is which on the wire; this is the pure split that lets the
/// System screen render two truthful sections — adopted rows behave exactly
/// as before, detached rows get their own section with re-add and clear.
public func hardwareSections(
    _ devices: [Components.Schemas.DeviceView]
) -> (adopted: [Components.Schemas.DeviceView], detached: [Components.Schemas.DeviceView]) {
    (devices.filter(\.adopted), devices.filter { !$0.adopted })
}
