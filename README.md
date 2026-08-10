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
