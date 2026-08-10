# Bella's Reef — iOS

Closed-source client for the [Bella's Reef](https://github.com/viperdavethesnake/bellas-reef)
controller. iOS 26+, SwiftUI.

## Build

```sh
brew install xcodegen
xcodegen generate
open BellasReef.xcodeproj
```

The `.xcodeproj` is generated and gitignored — `project.yml` is the source of
truth, so project structure is a reviewable diff instead of a pbxproj merge
conflict.

## Tests

Two kinds, and the difference matters.

`BellasReefKitTests` are offline and safe to run anywhere. `FrameDecodingTests`
decodes frames captured byte-for-byte off a real hub — including a faulted
reading whose `value` is null, which is the field `swift-openapi-generator`
silently dropped before the backend emitted OpenAPI 3.1 nullability.

`BellasReefUITests` is a **bench** test. It needs a hub advertising
`_bellasreef._tcp` on the LAN, spends a pairing window, and leaves a paired
client behind, so it never belongs in CI:

```sh
ssh <pi> 'cd ~/bellasreef && ./scripts/dev/…'   # ensure api + hardware-io are up
ssh <pi> '… uv run bellasreef pair --ttl 900'   # open a pairing window

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project BellasReef.xcodeproj -scheme BellasReef \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation
```

It walks discovery → identify → pair → a live temperature on screen. It exists
because every cheaper check passed while the app still showed an endless
spinner: the backend published, the socket served, the generated types decoded,
and discovery dropped every result on the floor.

## Contracts, and why nothing here is hand-typed

`Contracts/` holds `openapi.json` and `stream-frames.schema.json`, downloaded
from the backend's CI artifact and committed. `./scripts/pin-contracts.sh`
re-pins them.

`BellasReefKit/Sources/BellasReefAPI` contains **no hand-written code**. The
REST client and every model — including the WebSocket frame types — are
generated at build time by swift-openapi-generator. A backend contract change
becomes a compile error here. That is PRD G3, and it is the only thing keeping
this client honest about what the hub actually sends.

### The one exception

Per the PRD v1.3 G3 footnote, exactly one thing is hand-written:
**`StreamClient`'s transport** — connect, first-message auth, reconnect. It
exists because WebSockets cannot be described in OpenAPI 3.1.

It carries **no contract knowledge**. Every frame it receives is decoded into
generated types. If you find yourself adding a `struct` that mirrors something
the hub sends, stop: the fix belongs in the backend spec.

## Layout

| Path | |
|---|---|
| `BellasReef/` | app target — views, entry point |
| `BellasReefKit/Sources/BellasReefAPI/` | generated client (do not edit) |
| `BellasReefKit/Sources/BellasReefKit/` | theme, discovery, Keychain, stream transport |
| `Contracts/` | pinned specs from backend CI |
