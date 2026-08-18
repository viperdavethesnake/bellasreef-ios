# Pinned contracts

These are **not** edited here. They are downloaded from the backend's CI
artifact and committed, so a build is reproducible and a contract change is a
reviewable diff rather than something that shifts under the app.

| | |
|---|---|
| Backend commit | `10690ba` |
| CI run | [`32173078433`](https://github.com/viperdavethesnake/bellas-reef/actions/runs/32173078433) (`client-contracts` artifact) |
| Pinned on | 2026-08-18 |
| OpenAPI | 3.1.0, 23 paths |
| Contracts version | 4.0.0 |
| Frame schema | v1 |

## Refreshing

```sh
./scripts/pin-contracts.sh          # latest green run on main
./scripts/pin-contracts.sh <run-id> # a specific run
```

A refresh that changes generated types shows up as compile errors in
`BellasReefKit`. That is the point — PRD G3.

## What 3.0.0 → 3.5.0 added

Recorded because the gap, not any missing screen, is what made half the app's
adoption work impossible. The vendored spec sat at 3.0.0 while the hub served
3.5.0, so the generator faithfully produced a correct client for a contract five
minors out of date and every downstream check passed.

| Operation | Why it was missing from the app |
|---|---|
| `POST /api/v1/pair/claim` (`claimPairing`) | the second-device journey has no approver without it |
| `pairing_code` on the 202 pair body | the waiting device had nothing to display |
| `POST /api/v1/devices` (`bindDevice`) | device adoption had no method to call |
| `DELETE /api/v1/devices/{id}` (`unbindDevice`) | a wrongly-bound channel was taken forever |
| `GET /api/v1/capabilities` (`listCapabilities`) | — |

CI's "Contracts are in sync" step compares the two copies in *this* repo, which
catches a hand-edit and cannot catch this. The backend gained a CI step that
diffs its generated spec against its committed one; keeping these files current
still means running `pin-contracts.sh` after a backend contract change.

## What 3.5.0 → 3.6.0 added

`DeviceView` gained an optional `channel` (string, nullable): the binding's
physical channel (a PWM channel number or a 1-Wire ROM), `None` once the
device's binding is released. Additive and non-breaking — the generator's
`DeviceView` struct grows one more optional property, nothing else in the spec
moved. Lets an adopted-device row show which physical channel it claims,
matching the available-channel rows, which already showed it.

## What 3.6.0 → 3.7.0 added

The new-owner experience: a factory-reset hub has devices in its registry that
nobody has claimed yet, and this is the surface for readopting or forgetting
them.

| Symbol | Why it was missing from the app |
|---|---|
| `Info.setup_mode` (`setupMode`) | nothing told the client the hub is unclaimed and pairing wants a setup code |
| `PairRequest.setup_code` (`setupCode`) | the field that carries the code in setup mode; required/rejected server-side, not client-validated |
| `POST /api/v1/pair` 429 | setup-code attempts are now rate-limited; `pair()` gained a `tooManyRequests` outcome |
| `POST /api/v1/pair` 422 | dropped its typed `HTTPValidationError` body — description-only now, matching `bindDevice`/`history` |
| `AuditEvent.action` | the audit log's category system needed a machine-readable action alongside its free-text `event` |
| `DeviceView.adopted` (required, non-optional `Bool`) | distinguishes a device this owner has claimed from one left in the registry by a previous owner |
| `POST /api/v1/devices/{id}/readopt` (`readoptDevice`) | claims an unadopted device into this owner's registry |
| `POST /api/v1/devices/{id}/forget` (`forgetDevice`) | discards an unadopted device instead of claiming it |

`DeviceView.adopted` being required broke the one place in `BellasReefKit`
that hand-builds a `DeviceView` fixture
(`EquipmentRowsTests.EquipmentFixtures.device`) — updated to pass
`adopted: true`, since every fixture there represents an already-adopted
actuator. `HubClient.pair(clientName:)`'s switch gained a `.tooManyRequests`
case; the dropped typed 422 body needed no call-site change because the
existing `.unprocessableContent` case never read the body.

## What 3.7.0 → 3.8.0 added

Hold transition (backend spec 2026-08-17): an override carries how the light
moves to it and away from it.

| Symbol | Why it was missing from the app |
|---|---|
| `OverrideRequest.transition` (`snap` \| `ramp`, server default `ramp`) | the Lighting tab had no way to ask for a snap; every hold slewed at 1 %/s |
| `OverrideView.transition` (required) | the grant echoes what was asked, so the optimistic hold row can show it |
| `OverrideContext.transition` (required, on every state frame's `override`) | the active-hold row can say what will happen at release/expiry |

Additive. `OverrideView.transition` and `OverrideContext.transition` being
required broke the kit's hand-built fixtures (`OverrideTests` JSON stubs,
`LightingFixtures.override`) — updated to carry it, and `HubClient.hold`
gained a `transition:` parameter so the app always sends the choice
explicitly rather than relying on the server default.

## What 3.8.0 → 4.0.0 changed

Nothing on the wire. The backend made `open()` a required member of its
`ActuatorDriver` Protocol — the third versioned contract, the one hardware
drivers implement — and a required member added to a Protocol is MAJOR under
its own semver table (`docs/contracts/nats-subjects.md` §5), so the shared
version number moved. `openapi.json` differs from 3.8.0 in `info.version`
only; the generated client is byte-for-byte the same, no fixture moved, and
the `/info` screen simply reads `contracts 4.0.0` off the hub. Pinned so the
number the app shows is the number the hub serves.
