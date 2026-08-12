# Pinned contracts

These are **not** edited here. They are downloaded from the backend's CI
artifact and committed, so a build is reproducible and a contract change is a
reviewable diff rather than something that shifts under the app.

| | |
|---|---|
| Backend commit | `6567638` |
| CI run | exported locally from `6567638`; re-pin from the artifact once that run is green |
| Pinned on | 2026-08-12 |
| OpenAPI | 3.1.0, 21 paths |
| Contracts version | 3.5.0 |
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
