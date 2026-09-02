# CLAUDE.md — Bella's Reef iOS

SwiftUI client for the Bella's Reef hub. The backend repo's CLAUDE.md
(`../bellasreef/CLAUDE.md`) carries the platform rules — API-first, generated
client only, contracts pinned via `scripts/pin-contracts.sh`.

## Building from the CLI

`xcode-select -p` on this Mac points at CommandLineTools, and the
swift-openapi-generator build plugin needs validation skipped outside the
Xcode GUI. Both bite silently-ish; the working invocation is:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BellasReef.xcodeproj -scheme BellasReef \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation build
```

- Without `DEVELOPER_DIR`, `xcrun simctl` fails with "unable to find utility".
- Without `-skipPackagePluginValidation`, the build fails at
  `Validate plug-in "OpenAPIGenerator"`.
- Install + launch: `xcrun simctl install booted
  build/DerivedData/Build/Products/Debug-iphonesimulator/BellasReef.app`
  then `xcrun simctl launch booted com.bellasreef.app`.
- Simulators exist for several iOS runtimes; pick by `-destination` OS
  explicitly or two "iPhone 17 Pro" rows are ambiguous.

## Pairing a fresh install

A fresh app has no credentials. If the hub has ever paired a client, TOFU is
shut — open a window first, on the hub:

```bash
ssh bellasreef.local 'cd /home/david/bellasreef && docker compose \
  -f deploy/compose.yaml --env-file deploy/.env exec -T api bellasreef pair'
```

300 s window, spent by the first client that uses it. `/api/v1/info`'s
`paired_client_count` counts clients **ever** (it is the TOFU gate), not live
ones — `bellasreef revoke --list` on the hub is what shows live clients.

## Workflow

- Conventional commits; changes land via PR (CI runs the test scheme).
- Deferred-minors backlog lives in Claude's project memory
  (`ios-schedules-deferred-minors`, `ios-adopt-sheet-findings`) — check it
  when touching the schedules editor, curve views, or the adopt sheet.
- Errors reach a screen only via `HumanError.describe`; a raw error goes to a
  `log.` line, never into user-visible text. CI enforces it
  (`scripts/no-raw-errors.sh`).
