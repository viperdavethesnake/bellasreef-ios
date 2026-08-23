# Schedules UI + Hardware Chip State (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the app up to contracts 4.2.0 — re-pin the client, show per-chip
state on the System tab's Hardware leaf, and give lighting schedules their full
phase-1 surface (card mini-curve with a now dot at the wire duty, light detail
with the day curve, and a Schedules library/editor with assignment).

**Architecture:** Three PRs in backend-mirror order. PR 1 is the mechanical
re-pin (additive diff, zero expected compile breaks). PR 2 attaches
`ChipStateView` rows to `ChannelGroups` and renders one formatted line per
board header. PR 3 is greenfield schedules UI: a pure `ScheduleCurve` type
ports the engine's `duty_at` semantics exactly, a `ScheduleLibrary` store
follows the `DeviceCatalog` pattern, `lightingCards` gains schedule
association, and three view surfaces render it (card, light detail, library +
editor). All hub state stays wire-truth: the now dot plots the reported duty,
never the curve's own value.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI (iOS 26), Swift Charts
(detail + editor preview only; the card mini-curve is a `Path`, matching
`Sparkline`), swift-openapi-generator (plugin, build-time), swift-testing
(`@Suite`/`@Test`/`#expect`) in `BellasReefKitTests`.

**Specs:**
- `bellas-reef/docs/superpowers/specs/2026-08-19-lighting-schedules-design.md` §iOS (phase 1 surface)
- `bellas-reef/docs/superpowers/specs/2026-08-19-chip-state-on-the-wire-design.md` §iOS

## Global Constraints

- **No hand-written bindings.** The client is generated from the pinned
  `openapi.json`; the only sanctioned refresh is `./scripts/pin-contracts.sh
  <run-id>` followed by a hand-updated `Contracts/PINNED.md` (its format is a
  strict convention — pin table + one "What X → Y added" section).
- **Build/test commands** (Mac, this checkout; CI uses `name=iPhone 17 Pro`,
  locally the installed sim is the iPhone 17, UDID below):

  ```sh
  # kit unit tests — run from BellasReefKit/
  cd /Users/david/visualstudio/bellasreef-ios/BellasReefKit
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme BellasReefKit-Package \
    -destination 'platform=iOS Simulator,id=9438872C-7EF2-4BA7-837F-1C55F938E6DF' \
    -skipPackagePluginValidation

  # app build — run from the repo root
  cd /Users/david/visualstudio/bellasreef-ios
  brew list xcodegen >/dev/null || brew install xcodegen
  xcodegen generate
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -scheme BellasReef \
    -destination 'platform=iOS Simulator,id=9438872C-7EF2-4BA7-837F-1C55F938E6DF' \
    -skipPackagePluginValidation
  ```

  `swift test` is broken in this sandbox (pre-existing; recorded in the
  2026-08-17 plan) — always use `xcodebuild test`.
- **Conventional commits**, each ending with
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Branches / PRs:** PR 1 `chore/re-pin-4.2.0` (Task 1); PR 2
  `feat/hardware-chip-state` (Tasks 2–3); PR 3 `feat/lighting-schedules-ui`
  (Tasks 4–11). Each PR branches from main after the previous one merges.
- **CI gate:** the "Contracts are in sync" step diffs
  `Contracts/openapi.json` against
  `BellasReefKit/Sources/BellasReefAPI/openapi.json` — the pin script writes
  both; never edit either by hand.
- **Wire truth:** `reportedDuty == nil` means "no state yet" and is never
  rendered as 0%. The now dot on any curve plots the wire duty. "Returns to
  N %" is computed from the curve at the hold's expiry, client-side.
- **Generated-name assumptions to verify in Task 1** (all from
  `namingStrategy: idiomatic`): `assignedChannels`, `announcedAt`,
  `initialisedAt`; `ScheduleView.id` maps to Swift `String` (format `uuid` has
  no special-case in the generator); `SchedulePoint.at` maps to `String`
  (format `time` has no special case); `ChipStateView.FactsPayload` is a
  container whose `additionalProperties` values carry the anyOf as an
  optionals struct (`value1: String?`, `value2: Int?`, `value3: Double?`,
  `value4: Bool?`). Task 1 Step 5 checks all of these against the generated
  source; if any differs, fix the affected code in later tasks to the real
  name — the assumption tables in each task call out every use site.
- **Decisions to flag in PR bodies (not silently)**:
  1. PR 2 — **RULED by David 2026-08-23 (option 1); record in the PR body,
     don't ask:** the Hardware leaf builds a section per *announced* board
     (all capabilities) and lists only free channels in it, where it
     previously dropped fully-adopted boards entirely. Chip state only
     exists *because* a channel is adopted — under the old grouping the
     1-Wire bus (its single probe adopted) could never have shown its chip
     state at all.
  2. PR 3 — **RULED by David 2026-08-23 (confirmed go); record in the PR
     body, don't ask:** a schedule created from the app sends
     `zone = TimeZone.current.identifier` (not the server default `UTC`) —
     the times an operator types are the times on their wall clock, and the
     v2 famous-reefs feature requires exactly this value (`zone` is "the
     operator's day" the solar shape maps onto; `locale` is the reef —
     time-and-scheduling.md §2). Editing keeps the stored zone.
  3. PR 3: the editor pre-validates the curve client-side with the same rules
     as the hub's `validate_curve` (≥2 points, strictly ascending unique
     times, duty 0–1) because the wire 422 is description-only and carries no
     sentence to show.

---

### Task 1: Re-pin contracts to 4.2.0 (PR 1)

**Files:**
- Modify: `Contracts/openapi.json` (via script)
- Modify: `BellasReefKit/Sources/BellasReefAPI/openapi.json` (via script)
- Modify: `Contracts/PINNED.md`

**Interfaces:**
- Consumes: backend CI artifact `client-contracts` from repo
  `viperdavethesnake/bellas-reef`, latest green run on main (backend main is
  `e70beac7`, contracts 4.2.0).
- Produces: generated symbols every later task uses —
  `Components.Schemas.ScheduleView` (`anchor`, `assignedChannels: [String]`,
  `id`, `locale`, `name`, `points: [SchedulePoint]`, `zone`),
  `Components.Schemas.ScheduleRequest`, `Components.Schemas.SchedulePoint`
  (`at: String` "HH:MM:SS", `duty: Double`),
  `Components.Schemas.ScheduleAssignRequest`, `Components.Schemas.Locale`,
  `Components.Schemas.ChipStateView` (`source`, `instance`, `initialised`,
  `initialisedAt`, `facts`, `announcedAt`), and generated operations
  `listHardware`, `listSchedules`, `createSchedule`, `getSchedule`,
  `updateSchedule`, `deleteSchedule`, `assignSchedule`, `unassignSchedule`.

- [ ] **Step 1: Branch and re-pin**

```sh
cd /Users/david/visualstudio/bellasreef-ios
git checkout main && git pull
git checkout -b chore/re-pin-4.2.0
RUN_ID=$(gh run list -R viperdavethesnake/bellas-reef --branch main \
         --status success --limit 1 --json databaseId -q '.[0].databaseId')
echo "$RUN_ID"
./scripts/pin-contracts.sh "$RUN_ID"
```

Expected: script prints `pinned run <RUN_ID>` and a diff stat touching only
the two `openapi.json` copies (`stream-frames.schema.json` is byte-identical
at 4.2.0 — verified against backend main 2026-08-23).

- [ ] **Step 2: Confirm the diff is what the backend shipped**

```sh
python3 - <<'EOF'
import json
new = json.load(open('Contracts/openapi.json'))
assert new['info']['version'] == '4.2.0', new['info']['version']
print('paths:', len(new['paths']))
EOF
```

Expected: version `4.2.0`, `paths: 27` (23 + the 4 new: `/api/v1/hardware`,
`/api/v1/lighting/schedules`, `/api/v1/lighting/schedules/{schedule_id}`,
`/api/v1/lighting/channels/{channel_id}/schedule`).

- [ ] **Step 3: Update `Contracts/PINNED.md`**

Replace the pin table's values: Backend commit = the artifact run's head SHA
(from `gh run view $RUN_ID -R viperdavethesnake/bellas-reef --json headSha
-q .headSha`, short form), CI run = `$RUN_ID` with its URL, Pinned on =
2026-08-23, OpenAPI = `3.1.0, 27 paths`, Contracts version = `4.2.0`, Frame
schema = v1. Then append this section after the 3.8.0 → 4.0.0 one:

```markdown
## What 4.0.0 → 4.2.0 added

4.1.0 is the lighting schedule library (backend spec 2026-08-19, PR #60);
4.2.0 is chip state on the wire (spec 2026-08-19, PRs #61/#62). Both minors
are additive; no generated type changed shape, so no fixture broke — the work
is new `HubClient` wrappers and new screens, not repair.

| Symbol | Why it was missing from the app |
|---|---|
| `GET/POST /api/v1/lighting/schedules` (`listSchedules`/`createSchedule`) | the schedule library had no surface |
| `GET/PUT/DELETE /api/v1/lighting/schedules/{id}` (`getSchedule`/`updateSchedule`/`deleteSchedule`) | edit/rename/delete of a curve |
| `PUT/DELETE /api/v1/lighting/channels/{channel_id}/schedule` (`assignSchedule`/`unassignSchedule`) | a curve could not be pointed at a light |
| `ScheduleView` / `ScheduleRequest` / `SchedulePoint` / `ScheduleAssignRequest` / `Locale` | the curve's wire shape (`points` are `{at: "HH:MM:SS", duty: 0–1}`; `Locale` is schema-now, consumed by solar v2) |
| `GET /api/v1/hardware` (`listHardware`) | the Hardware leaf had no per-chip data source (option A ruling, 2026-08-18) |
| `ChipStateView` | what a chip's own registers say — prescaler, measured oscillator, INVRT, initialised |

`forgetDevice` changed description text only — same response codes, no
call-site change.
```

- [ ] **Step 4: Regenerate the project and build both units**

Run the kit test command and the app build command from Global Constraints.
Expected: both green with **zero source changes** — the diff is additive.

- [ ] **Step 5: Verify the generated-name assumptions**

```sh
GEN=$(find ~/Library/Developer/Xcode/DerivedData -path '*BellasReefAPI*' -name 'Types.swift' | head -1)
grep -n "struct ScheduleView" -A 30 "$GEN" | head -40
grep -n "struct ChipStateView" -A 40 "$GEN" | head -50
grep -n "struct SchedulePoint" -A 10 "$GEN"
```

Confirm against the Global Constraints assumption list: `assignedChannels:
[Swift.String]`, `id: Swift.String`, `at: Swift.String`, and the
`FactsPayload.AdditionalPropertiesPayload` optionals struct
(`value1/value2/value3/value4`). Record any deviation in the task report —
Tasks 3, 5, 7 name every use site.

- [ ] **Step 6: Commit and open PR 1**

```sh
git add Contracts BellasReefKit/Sources/BellasReefAPI/openapi.json
git commit -m "chore(contracts): re-pin to 4.2.0 (schedules + chip state)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin chore/re-pin-4.2.0
gh pr create --title "chore(contracts): re-pin to 4.2.0 (schedules + chip state)" \
  --body "Additive re-pin: 4 new paths (7 schedule ops + listHardware), 6 new schemas. Frame schema unchanged. Zero source changes — build and tests green untouched.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

### Task 2: `HubClient.hardware()` (PR 2)

**Files:**
- Modify: `BellasReefKit/Sources/BellasReefKit/HubClient.swift` (after
  `capabilities()`, which ends at line 249)
- Create: `BellasReefKit/Tests/BellasReefKitTests/HardwareClientTests.swift`

**Interfaces:**
- Consumes: generated `client.listHardware()` (Task 1).
- Produces: `public func hardware() async throws -> [Components.Schemas.ChipStateView]`
  on `HubClient` — Task 3's SystemView change calls it.

- [ ] **Step 1: Write the failing test**

`HardwareClientTests.swift` — `StubTransport`/`MemoryCredentials` are shared
from PairingTests.swift; `anyHub`/`json`/`stub` are file-private there, so
this file keeps its own copies (the same choice OverrideTests.swift:8-29
documents — copy that exact idiom):

```swift
// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

private let anyHub = Hub(
    name: "Bella's Reef", baseURL: URL(string: "http://hub.invalid:8000")!, discovered: false
)

private func json(_ text: String) -> Data { Data(text.utf8) }

private func stub(_ handler: @escaping @Sendable (String) async throws -> (Int, Data?)) -> HubClient {
    HubClient(
        hub: anyHub, tokens: MemoryCredentials(token: "refresh"),
        transport: StubTransport { operation, _, _ in
            if operation == "mintToken" {
                return (200, json(#"{"access_token":"jwt","expires_in":900}"#))
            }
            return try await handler(operation)
        }
    )
}

@Suite("Hardware wrapper")
struct HardwareClientTests {

    /// The three chips the bench hub actually announces today, verbatim
    /// shapes from `GET /api/v1/hardware` (backend #62): facts values mix
    /// strings, ints, floats and bools, and every one must survive decoding.
    @Test("a 200 decodes every chip row, facts included")
    func hardwareDecodes() async throws {
        let client = stub { operation in
            #expect(operation == "listHardware")
            return (200, json(#"""
                [{"source": "pca9685", "instance": "0x40@1", "initialised": true,
                  "initialised_at": "2026-08-22T01:30:00Z",
                  "facts": {"address": "0x40", "bus": 1, "pre_scale": 12,
                            "frequency_hz": 502.7, "oscillator_hz": 26770000,
                            "invrt": false, "open_drain": false, "channels": 16,
                            "pre_scale_read_back": 12},
                  "announced_at": "2026-08-22T01:30:00Z"},
                 {"source": "pi-pwm", "instance": "1f00098000.pwm", "initialised": true,
                  "initialised_at": "2026-08-22T01:30:00Z",
                  "facts": {"chip": "pwmchip0", "device": "1f00098000.pwm",
                            "period_ns": 2000000, "frequency_hz": 500.0,
                            "polarity": "normal", "channels": 4},
                  "announced_at": "2026-08-22T01:30:00Z"},
                 {"source": "w1-bus", "instance": "w1_bus_master1", "initialised": true,
                  "initialised_at": "2026-08-22T01:30:00Z",
                  "facts": {"bus_master": "w1_bus_master1", "probes": 1},
                  "announced_at": "2026-08-22T01:30:00Z"}]
                """#))
        }
        let chips = try await client.hardware()
        #expect(chips.count == 3)
        #expect(chips[0].source == "pca9685")
        #expect(chips[0].instance == "0x40@1")
        #expect(chips[0].initialised == true)
        #expect(chips[1].facts.additionalProperties["polarity"]?.value1 == "normal")
        #expect(chips[2].facts.additionalProperties["probes"]?.value2 == 1)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL** (`hardware()` does not exist) with the
kit test command from Global Constraints, narrowed:
`-only-testing:BellasReefKitTests/HardwareClientTests`.

- [ ] **Step 3: Implement the wrapper** in `HubClient.swift`, directly after
`capabilities()` (house style: exhaustive switch, documented non-2xx to named
outcomes — here there are none, so failures throw):

```swift
    /// What each chip last reported about itself (`GET /api/v1/hardware`) —
    /// the Hardware leaf's per-board second line. Register-level facts, not
    /// capabilities: a capability is what channels a board offers, this is
    /// what the chip's own registers said when hardware-io brought it up.
    public func hardware() async throws -> [Components.Schemas.ChipStateView] {
        switch try await client.listHardware() {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the hardware query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("hardware returned \(statusCode)")
        }
    }
```

- [ ] **Step 4: Run the test — expect PASS.** If `value1`/`value2` access
fails to compile, the generator named the anyOf payload differently — check
the generated source (Task 1 Step 5's `find`) and align the test to the real
accessor; record it, because Task 3's fact helpers use the same accessors.

- [ ] **Step 5: Commit**

```sh
git add BellasReefKit
git commit -m "feat(kit): HubClient.hardware() — chip state rows from GET /api/v1/hardware

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Chip state on the Hardware leaf (PR 2)

**Files:**
- Modify: `BellasReefKit/Sources/BellasReefKit/ChannelGroups.swift`
- Modify: `BellasReef/Views/SystemView.swift:260-319` (`hardwareLeaf`),
  `SystemView.swift:592-606` (`loadHardware()`), plus the `@State` block that
  holds `capabilities`/`hardwareFailed`
- Test: `BellasReefKit/Tests/BellasReefKitTests/ChannelGroupsTests.swift`

**Interfaces:**
- Consumes: `HubClient.hardware()` (Task 2);
  `Components.Schemas.ChipStateView` (Task 1).
- Produces:
  `ChannelGroups.group(_ channels: [Components.Schemas.CapabilityView], chipStates: [Components.Schemas.ChipStateView] = []) -> [Group]`
  (the existing one-argument call sites keep compiling via the default);
  `Group.state: Components.Schemas.ChipStateView?`;
  `Group.stateLine: String`.

- [ ] **Step 1: Write the failing tests** (append to the existing
`ChannelGroupsTests.swift`, reusing its local `cap(_:_:_:)` helper for
capabilities; add a chip fixture helper beside it):

```swift
    /// Hand-built ChipStateView rows — same idiom as `cap`: generated inits
    /// take alphabetically ordered labels (announcedAt, facts, initialised,
    /// initialisedAt, instance, source).
    private func chip(
        _ source: String, _ facts: [String: Components.Schemas.ChipStateView.FactsPayload.AdditionalPropertiesPayload],
        initialised: Bool = true
    ) -> Components.Schemas.ChipStateView {
        .init(
            announcedAt: Date(timeIntervalSince1970: 1_787_000_000),
            facts: .init(additionalProperties: facts),
            initialised: initialised,
            initialisedAt: Date(timeIntervalSince1970: 1_787_000_000),
            instance: "test-instance",
            source: source
        )
    }

    @Test("chip state attaches to its board's group by source")
    func chipStateAttaches() {
        let groups = ChannelGroups.group(
            [cap(.pca9685, "0", ["address": "0x40"])],
            chipStates: [chip("pca9685", ["channels": .init(value2: 16)])]
        )
        #expect(groups.count == 1)
        #expect(groups[0].state != nil)
    }

    @Test("PCA9685 state line: initialised · frequency · INVRT · channels")
    func pcaStateLine() {
        let group = ChannelGroups.group(
            [cap(.pca9685, "0", [:])],
            chipStates: [chip("pca9685", [
                "frequency_hz": .init(value3: 502.7),
                "invrt": .init(value4: false),
                "channels": .init(value2: 16),
            ])]
        )[0]
        #expect(group.stateLine == "initialised · 502.7 Hz · INVRT off · 16 channels")
    }

    @Test("Pi PWM state line: frequency · polarity · channels, whole hertz without decimals")
    func piPwmStateLine() {
        let group = ChannelGroups.group(
            [cap(.piPwm, "0", [:])],
            chipStates: [chip("pi-pwm", [
                "frequency_hz": .init(value3: 500.0),
                "polarity": .init(value1: "normal"),
                "channels": .init(value2: 4),
            ])]
        )[0]
        #expect(group.stateLine == "500 Hz · normal · 4 channels")
    }

    @Test("1-Wire state line pluralises probes")
    func w1StateLine() {
        let one = ChannelGroups.group(
            [cap(.w1Bus, "28-000000bfe244", [:])],
            chipStates: [chip("w1-bus", ["probes": .init(value2: 1)])]
        )[0]
        #expect(one.stateLine == "1 probe")
        let three = ChannelGroups.group(
            [cap(.w1Bus, "28-000000bfe244", [:])],
            chipStates: [chip("w1-bus", ["probes": .init(value2: 3)])]
        )[0]
        #expect(three.stateLine == "3 probes")
    }

    @Test("a board with no chip state says why, in the spec's words")
    func noStateLine() {
        let group = ChannelGroups.group([cap(.pca9685, "0", [:])])[0]
        #expect(group.stateLine == "not initialised — no channel adopted")
    }
```

- [ ] **Step 2: Run — expect FAIL** (no `chipStates:` parameter, no
`stateLine`). Narrow with `-only-testing:BellasReefKitTests/ChannelGroupsTests`.

- [ ] **Step 3: Implement in `ChannelGroups.swift`**

Add to `Group` (after `shared`, line 19):

```swift
        /// What this board's chip last said about itself, when anything on
        /// it has been adopted — `initialise()` only runs at adoption, so an
        /// untouched board legitimately has no row (spec 2026-08-19 §iOS).
        public let state: Components.Schemas.ChipStateView?
```

Add after `subtitle` (line 36):

```swift
        /// The chip's own account, one line, in the spec's exact shapes:
        /// `initialised · 502.7 Hz · INVRT off · 16 channels` (PCA9685),
        /// `500 Hz · normal · 4 channels` (Pi PWM), `1 probe` (1-Wire).
        /// Facts a chip did not report are skipped, not rendered as blanks.
        public var stateLine: String {
            guard let state else { return "not initialised — no channel adopted" }
            var parts: [String] = []
            switch source {
            case .pca9685:
                parts.append(state.initialised ? "initialised" : "not initialised")
                if let hz = fact(double: "frequency_hz") { parts.append(Self.hertz(hz)) }
                if let invrt = fact(bool: "invrt") { parts.append(invrt ? "INVRT on" : "INVRT off") }
                if let n = fact(int: "channels") { parts.append("\(n) channels") }
            case .piPwm:
                if let hz = fact(double: "frequency_hz") { parts.append(Self.hertz(hz)) }
                if let polarity = fact(string: "polarity") { parts.append(polarity) }
                if let n = fact(int: "channels") { parts.append("\(n) channels") }
            case .w1Bus:
                if let n = fact(int: "probes") { parts.append(n == 1 ? "1 probe" : "\(n) probes") }
            }
            return parts.joined(separator: " · ")
        }

        /// 500.0 reads "500 Hz"; 502.7 reads "502.7 Hz" — a decimal is shown
        /// only when it carries information.
        private static func hertz(_ hz: Double) -> String {
            hz == hz.rounded() ? "\(Int(hz)) Hz" : String(format: "%.1f Hz", hz)
        }

        private func fact(string key: String) -> String? {
            state?.facts.additionalProperties[key]?.value1
        }
        private func fact(int key: String) -> Int? {
            state?.facts.additionalProperties[key]?.value2
        }
        private func fact(double key: String) -> Double? {
            guard let value = state?.facts.additionalProperties[key] else { return nil }
            return value.value3 ?? value.value2.map(Double.init)
        }
        private func fact(bool key: String) -> Bool? {
            state?.facts.additionalProperties[key]?.value4
        }
```

(`fact(double:)` falls back through `value2` because JSON `500` decodes as
the anyOf's integer branch while `500.0` decodes as its number branch — which
branch a given hub emits is a serializer detail the UI must not depend on.)

Change `group(_:)` (line 49) to:

```swift
    public static func group(
        _ channels: [Components.Schemas.CapabilityView],
        chipStates: [Components.Schemas.ChipStateView] = []
    ) -> [Group] {
```

and the `Group` construction (line 67) to:

```swift
            return Group(
                source: source, channels: sorted, shared: shared,
                state: chipStates.first { $0.source == source.rawValue }
            )
```

- [ ] **Step 4: Run the ChannelGroups tests — expect PASS.**

- [ ] **Step 5: Render it in `SystemView`**

Add state alongside `capabilities` (named to avoid `loadEverything()`'s local
`async let hardware` at line 572):

```swift
    @State private var chipStates: [Components.Schemas.ChipStateView] = []
```

In `loadHardware()` (line 592), add a third concurrent fetch, best-effort on
its own — a hub one deploy behind must not blank the whole leaf:

```swift
    private func loadHardware() async {
        guard let client = model.client else {
            hardwareFailed = true
            return
        }
        do {
            async let caps = client.capabilities()
            async let devs = client.devices()
            capabilities = try await caps
            hardwareDevices = try await devs
            hardwareFailed = false
        } catch {
            hardwareFailed = true
        }
        // Separate do/catch: chip state is a 4.2.0 surface; a hub that
        // predates it should degrade to the old leaf, not to a failure row.
        do {
            chipStates = try await client.hardware()
        } catch {
            chipStates = []
        }
    }
```

In `hardwareLeaf` (lines 260-289): group **all** capabilities so a
fully-adopted board keeps its section (PR-body flag #1), list only free
channels, and add the state line to the header:

```swift
    private var hardwareLeaf: some View {
        List {
            if let capabilities {
                if capabilities.isEmpty {
                    Section {
                        Text("The hub has not announced any hardware.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                ForEach(ChannelGroups.group(capabilities, chipStates: chipStates)) { group in
                    Section {
                        let free = group.channels.filter { $0.boundTo == nil }
                        if free.isEmpty {
                            Text("Every channel on this board is adopted.")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        ForEach(free) { capability in
                            Button { adopting = capability } label: {
                                availableRow(capability, detail: group.rowDetail(for: capability))
                            }
                            .accessibilityIdentifier("hardware-available-channel")
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                            if !group.subtitle.isEmpty {
                                Text(group.subtitle).textCase(nil)
                            }
                            Text(group.stateLine).textCase(nil)
                        }
                    }
                }
```

(the trailing `if hardwareFailed`, footer Section, `else if
hardwareFailed`/`else` branches, and the `.scrollContentBackground`/
`.reefBackground()`/`.navigationTitle`/`.refreshable` modifiers at lines
290-319 are unchanged — the old top-level `let free` and its
"Every announced channel is adopted." message are removed, replaced by the
per-board copy above).

- [ ] **Step 6: Full kit tests + app build — expect green.**

- [ ] **Step 7: Commit and open PR 2**

```sh
git add BellasReefKit BellasReef
git commit -m "feat(system): chip state on the Hardware leaf — per-board second line

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin feat/hardware-chip-state
gh pr create --title "feat(system): chip state on the Hardware leaf" --body "..."
```

PR body must carry decision flag #1 from Global Constraints.

---

### Task 4: `ScheduleCurve` — the engine's `duty_at`, ported exactly (PR 3)

**Files:**
- Create: `BellasReefKit/Sources/BellasReefKit/ScheduleCurve.swift`
- Test: `BellasReefKit/Tests/BellasReefKitTests/ScheduleCurveTests.swift`

**Interfaces:**
- Consumes: `Components.Schemas.ScheduleView` (Task 1).
- Produces (used by Tasks 7–10):

```swift
public struct ScheduleCurve: Equatable, Hashable, Sendable {
    public struct Point: Equatable, Hashable, Sendable {
        public let seconds: Int      // of local day, 0..<86400
        public let duty: Double      // 0...1
        public init(seconds: Int, duty: Double)
    }
    public let points: [Point]       // ≥2, strictly ascending unique seconds
    public let zone: TimeZone
    public init?(points: [Point], zoneIdentifier: String)
    public init?(_ schedule: Components.Schemas.ScheduleView)
    public func duty(at instant: Date) -> Double
    public func secondsOfDay(for instant: Date) -> Int
    public func nextPoint(after instant: Date) -> Point
    public var plotPoints: [Point]   // curve incl. synthesized 0 / 86400 endpoints
    public static func seconds(fromWireTime: String) -> Int?   // "HH:MM:SS" (or "HH:MM")
    public static func wireTime(fromSeconds: Int) -> String    // "HH:MM:SS"
}
```

**Reference semantics** (port of
`bellas-reef/services/control_engine/bellasreef_control_engine/profiles.py:97-135`
— the engine's own `duty_at`, the one source of truth):
convert the instant into the schedule's zone; `now_s = h*3600 + m*60 + s`;
if `now_s < first.seconds || now_s >= last.seconds` it is on the wrap segment:
`span = (first.seconds + 86400) - last.seconds`,
`elapsed = ((now_s - last.seconds) % 86400 + 86400) % 86400` (Swift `%` is
remainder, not modulo — Python's `%` is why the backend writes it bare),
lerp `last.duty → first.duty`; otherwise lerp within the bracketing segment
`[lo, hi)`. Clamp every lerp result to `0...1`.

- [ ] **Step 1: Write the failing tests**

```swift
// Bella's Reef iOS — closed source.

import Foundation
import Testing

@testable import BellasReefKit

@Suite("ScheduleCurve — the engine's duty_at, ported")
struct ScheduleCurveTests {

    /// 08:00 → 20%, 20:00 → 80%, UTC. Same shape the backend's own
    /// profile tests use: one rising day segment, one wrap segment.
    private var curve: ScheduleCurve {
        ScheduleCurve(
            points: [.init(seconds: 28_800, duty: 0.2), .init(seconds: 72_000, duty: 0.8)],
            zoneIdentifier: "UTC"
        )!
    }

    /// A UTC instant on 2026-08-23 at the given seconds-of-day, built from
    /// components so no hand-computed epoch constant can be wrong.
    private func utc(_ secondsOfDay: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 23
        comps.hour = secondsOfDay / 3600
        comps.minute = secondsOfDay % 3600 / 60
        comps.second = secondsOfDay % 60
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }

    @Test("a point's own instant returns its duty")
    func atAPoint() {
        #expect(curve.duty(at: utc(28_800)) == 0.2)
    }

    @Test("the day segment interpolates linearly")
    func daySegment() {
        // 14:00 is halfway from 08:00 to 20:00.
        #expect(abs(curve.duty(at: utc(50_400)) - 0.5) < 1e-9)
    }

    @Test("the wrap segment interpolates through midnight — no step at the darkest hour")
    func wrapSegment() {
        // 20:00→08:00(+1d) spans 12h; 02:00 is 6h in — halfway from 0.8 to 0.2.
        #expect(abs(curve.duty(at: utc(7_200)) - 0.5) < 1e-9)
        // The last point itself sits on the wrap segment (now_s >= last).
        #expect(curve.duty(at: utc(72_000)) == 0.8)
    }

    @Test("the instant is converted into the schedule's zone before lookup")
    func zoneConversion() {
        let pacific = ScheduleCurve(
            points: [.init(seconds: 28_800, duty: 0.2), .init(seconds: 72_000, duty: 0.8)],
            zoneIdentifier: "America/Los_Angeles"
        )!
        // 2026-08-23T15:00:00Z is 08:00 PDT — exactly the first point.
        #expect(pacific.duty(at: utc(54_000)) == 0.2)
    }

    @Test("plotPoints closes the day: identical synthesized values at 0 and 86400")
    func plotPointsEndpoints() {
        let plotted = curve.plotPoints
        #expect(plotted.first!.seconds == 0)
        #expect(plotted.last!.seconds == 86_400)
        // Midnight is 4h into the 12h wrap from 0.8 to 0.2 → 0.6.
        #expect(abs(plotted.first!.duty - 0.6) < 1e-9)
        #expect(plotted.first!.duty == plotted.last!.duty)
        #expect(plotted.count == 4)
    }

    @Test("a first point at second 0 is not duplicated by plotPoints")
    func plotPointsFirstAtMidnight() {
        let flat = ScheduleCurve(
            points: [.init(seconds: 0, duty: 0.1), .init(seconds: 43_200, duty: 0.9)],
            zoneIdentifier: "UTC"
        )!
        #expect(flat.plotPoints.map(\.seconds) == [0, 43_200, 86_400])
        #expect(flat.plotPoints.last!.duty == flat.plotPoints.first!.duty)
    }

    @Test("nextPoint walks forward and wraps")
    func nextPointWraps() {
        #expect(curve.nextPoint(after: utc(50_400)).seconds == 72_000)  // 14:00 → 20:00
        #expect(curve.nextPoint(after: utc(75_600)).seconds == 28_800)  // 21:00 → 08:00
    }

    @Test("wire time round-trips, tolerating HH:MM")
    func wireTime() {
        #expect(ScheduleCurve.seconds(fromWireTime: "08:00:00") == 28_800)
        #expect(ScheduleCurve.seconds(fromWireTime: "08:00") == 28_800)
        #expect(ScheduleCurve.seconds(fromWireTime: "24:00:00") == nil)
        #expect(ScheduleCurve.seconds(fromWireTime: "nonsense") == nil)
        #expect(ScheduleCurve.wireTime(fromSeconds: 28_800) == "08:00:00")
    }

    @Test("invalid curves refuse to construct, matching the hub's validate_curve")
    func invalidCurves() {
        // one point is a constant, not a schedule
        #expect(ScheduleCurve(points: [.init(seconds: 0, duty: 0.5)], zoneIdentifier: "UTC") == nil)
        // times must strictly ascend
        #expect(ScheduleCurve(
            points: [.init(seconds: 100, duty: 0.5), .init(seconds: 100, duty: 0.6)],
            zoneIdentifier: "UTC") == nil)
        // duty is 0...1
        #expect(ScheduleCurve(
            points: [.init(seconds: 0, duty: 0.5), .init(seconds: 100, duty: 1.2)],
            zoneIdentifier: "UTC") == nil)
        // the zone must resolve
        #expect(ScheduleCurve(
            points: [.init(seconds: 0, duty: 0.5), .init(seconds: 100, duty: 0.6)],
            zoneIdentifier: "Neptune/Trench") == nil)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (type does not exist).

- [ ] **Step 3: Implement `ScheduleCurve.swift`**

```swift
// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation

/// A schedule's curve as pure maths: the engine's `duty_at`
/// (`profiles.py`, contracts §time-and-scheduling) ported so that what this
/// app draws and predicts is what the hub will actually emit. Linear between
/// ascending points; the segment from the last point back to the first
/// interpolates *through* midnight — a flat treatment would put a step at
/// exactly the darkest hour, where it is least wanted and most visible.
public struct ScheduleCurve: Equatable, Hashable, Sendable {

    public struct Point: Equatable, Hashable, Sendable {
        public let seconds: Int
        public let duty: Double

        public init(seconds: Int, duty: Double) {
            self.seconds = seconds
            self.duty = duty
        }
    }

    public let points: [Point]
    public let zone: TimeZone

    /// The hub's own `validate_curve` rules, applied at construction: at
    /// least two points, strictly ascending unique times inside one day,
    /// duty within 0...1, and a zone the platform can resolve. A curve that
    /// fails them renders as absent rather than as a guess.
    public init?(points: [Point], zoneIdentifier: String) {
        guard points.count >= 2,
              let zone = TimeZone(identifier: zoneIdentifier),
              points.allSatisfy({ (0..<86_400).contains($0.seconds) && (0.0...1.0).contains($0.duty) }),
              zip(points, points.dropFirst()).allSatisfy({ $0.seconds < $1.seconds })
        else { return nil }
        self.points = points
        self.zone = zone
    }

    public init?(_ schedule: Components.Schemas.ScheduleView) {
        let parsed = schedule.points.compactMap { point -> Point? in
            guard let seconds = Self.seconds(fromWireTime: point.at) else { return nil }
            return Point(seconds: seconds, duty: point.duty)
        }
        guard parsed.count == schedule.points.count else { return nil }
        self.init(points: parsed, zoneIdentifier: schedule.zone)
    }

    /// Interpolated duty for `instant`, converted into the schedule's zone
    /// first — same contract as the engine's, so the caller can stay in the
    /// device's clock.
    public func duty(at instant: Date) -> Double {
        duty(atSecondsOfDay: secondsOfDay(for: instant))
    }

    /// Seconds since local midnight in the *schedule's* zone — the x-position
    /// of "now" on any drawing of this curve.
    public func secondsOfDay(for instant: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let comps = calendar.dateComponents([.hour, .minute, .second], from: instant)
        return (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
    }

    /// The next anchor the curve will reach after `instant`, wrapping past
    /// midnight — "35 % at 19:00" on the light detail screen. Always exists:
    /// a curve has at least two points.
    public func nextPoint(after instant: Date) -> Point {
        let now = secondsOfDay(for: instant)
        return points.first { $0.seconds > now } ?? points[0]
    }

    /// The curve as drawn midnight-to-midnight: the real points, plus
    /// synthesized endpoints at 0 and 86400 carrying the wrap segment's
    /// value there, so the plotted line spans the whole day and its two ends
    /// meet at the same duty.
    public var plotPoints: [Point] {
        let atMidnight = duty(atSecondsOfDay: 0)
        var plotted = points
        if points[0].seconds != 0 {
            plotted.insert(Point(seconds: 0, duty: atMidnight), at: 0)
        }
        plotted.append(Point(seconds: 86_400, duty: atMidnight))
        return plotted
    }

    private func duty(atSecondsOfDay now: Int) -> Double {
        let first = points[0], last = points[points.count - 1]
        if now < first.seconds || now >= last.seconds {
            let span = (first.seconds + 86_400) - last.seconds
            guard span != 0 else { return last.duty }
            // Swift's % is remainder (sign-preserving); Python's is modulo.
            // The backend writes `(now - last) % 86400` and relies on the
            // modulo; matching it needs the double-% normalisation here.
            let elapsed = ((now - last.seconds) % 86_400 + 86_400) % 86_400
            return Self.lerp(last.duty, first.duty, Double(elapsed) / Double(span))
        }
        for (lo, hi) in zip(points, points.dropFirst()) where lo.seconds <= now && now < hi.seconds {
            let span = hi.seconds - lo.seconds
            return Self.lerp(lo.duty, hi.duty, Double(now - lo.seconds) / Double(span))
        }
        return last.duty
    }

    /// Endpoint-guarded, exactly like the engine's `_lerp`: a duty of
    /// 1.0000000000000002 would fail the wire contract's `le=1.0` on the
    /// next PUT, taking a channel out on a rounding error.
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        min(1.0, max(0.0, a + (b - a) * t))
    }

    /// "HH:MM:SS" (the wire form Pydantic emits) or "HH:MM" → seconds of
    /// day. Strict otherwise: a malformed time is nil, not a guess.
    public static func seconds(fromWireTime text: String) -> Int? {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count) else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == fields.count else { return nil }
        let hour = numbers[0], minute = numbers[1]
        let second = numbers.count == 3 ? numbers[2] : 0
        guard (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second)
        else { return nil }
        return hour * 3600 + minute * 60 + second
    }

    public static func wireTime(fromSeconds seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }
}
```

- [ ] **Step 4: Run the ScheduleCurve tests — expect PASS.**

- [ ] **Step 5: Commit**

```sh
git add BellasReefKit
git commit -m "feat(kit): ScheduleCurve — the engine's duty_at semantics, ported and tested

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `HubClient` schedule wrappers (PR 3)

**Files:**
- Modify: `BellasReefKit/Sources/BellasReefKit/HubClient.swift` (new
  `// MARK: Schedules` section after the overrides block, i.e. after
  `release(overrideId:)` ends at ~line 524)
- Create: `BellasReefKit/Tests/BellasReefKitTests/ScheduleClientTests.swift`

**Interfaces:**
- Consumes: generated schedule operations (Task 1).
- Produces (Tasks 6, 9, 10 call these — signatures verbatim):

```swift
public func schedules() async throws -> [Components.Schemas.ScheduleView]

public enum ScheduleSaveOutcome: Sendable {
    case saved(Components.Schemas.ScheduleView)   // 200
    case nameTaken                                // 409
    case curveRejected                            // 422 (description-only on the wire)
    case unknownSchedule                          // 404 (update only)
}
public func createSchedule(_ request: Components.Schemas.ScheduleRequest) async throws -> ScheduleSaveOutcome
public func updateSchedule(id: String, _ request: Components.Schemas.ScheduleRequest) async throws -> ScheduleSaveOutcome

public enum ScheduleDeleteOutcome: Sendable, Equatable {
    case deleted            // 204
    case stillAssigned      // 409 — unassign first
    case unknown            // 404
}
public func deleteSchedule(id: String) async throws -> ScheduleDeleteOutcome

public enum AssignOutcome: Sendable {
    case assigned(Components.Schemas.ScheduleView)  // 200, echoes the schedule
    case notCommandable                             // 409 — observe_only channel
    case unknownSchedule                            // 404
}
public func assignSchedule(channelId: String, scheduleId: String) async throws -> AssignOutcome

public enum UnassignOutcome: Sendable, Equatable {
    case unassigned         // 200
    case nothingAssigned    // 404
}
public func unassignSchedule(channelId: String) async throws -> UnassignOutcome
```

- [ ] **Step 1: Write the failing tests** (`ScheduleClientTests.swift`; same
file-private `anyHub`/`json`/`stub` copies as Task 2 Step 1 — repeat them
verbatim at the top of this file):

```swift
@Suite("Schedule wrappers")
struct ScheduleClientTests {

    private static let scheduleJSON = #"""
        {"id": "6f1e4e2a-1111-4222-8333-444455556666", "name": "Reef day",
         "zone": "America/Los_Angeles", "anchor": "clock",
         "points": [{"at": "08:00:00", "duty": 0.0}, {"at": "12:00:00", "duty": 0.6},
                    {"at": "20:00:00", "duty": 0.0}],
         "assigned_channels": ["pi-pwm-0"]}
        """#

    @Test("the list decodes points, zone and assignments")
    func listDecodes() async throws {
        let client = stub { operation in
            #expect(operation == "listSchedules")
            return (200, json("[\(Self.scheduleJSON)]"))
        }
        let schedules = try await client.schedules()
        #expect(schedules.count == 1)
        #expect(schedules[0].name == "Reef day")
        #expect(schedules[0].points.count == 3)
        #expect(schedules[0].points[0].at == "08:00:00")
        #expect(schedules[0].assignedChannels == ["pi-pwm-0"])
    }

    @Test("create: 200 carries the created schedule; 409 is a name collision, not an error")
    func createOutcomes() async throws {
        let created = stub { _ in (200, json(Self.scheduleJSON)) }
        let request = Components.Schemas.ScheduleRequest(
            name: "Reef day",
            points: [.init(at: "08:00:00", duty: 0.0), .init(at: "20:00:00", duty: 0.6)],
            zone: "America/Los_Angeles"
        )
        guard case let .saved(schedule) = try await created.createSchedule(request) else {
            Issue.record("expected .saved")
            return
        }
        #expect(schedule.name == "Reef day")

        let collided = stub { _ in (409, nil) }
        guard case .nameTaken = try await collided.createSchedule(request) else {
            Issue.record("expected .nameTaken")
            return
        }
    }

    @Test("update: 404 is its own case — the library on screen is stale")
    func updateUnknown() async throws {
        let client = stub { _ in (404, nil) }
        let request = Components.Schemas.ScheduleRequest(
            name: "Reef day",
            points: [.init(at: "08:00:00", duty: 0.0), .init(at: "20:00:00", duty: 0.6)]
        )
        guard case .unknownSchedule = try await client.updateSchedule(
            id: "6f1e4e2a-1111-4222-8333-444455556666", request
        ) else {
            Issue.record("expected .unknownSchedule")
            return
        }
    }

    @Test("delete: 409 means still assigned — unassign first, in the hub's own rule")
    func deleteStillAssigned() async throws {
        let client = stub { _ in (409, nil) }
        #expect(try await client.deleteSchedule(
            id: "6f1e4e2a-1111-4222-8333-444455556666") == .stillAssigned)
    }

    @Test("assign: 200 echoes the schedule; 409 is observe_only")
    func assignOutcomes() async throws {
        let granted = stub { operation in
            #expect(operation == "assignSchedule")
            return (200, json(Self.scheduleJSON))
        }
        guard case .assigned = try await granted.assignSchedule(
            channelId: "pi-pwm-0", scheduleId: "6f1e4e2a-1111-4222-8333-444455556666"
        ) else {
            Issue.record("expected .assigned")
            return
        }
        let refused = stub { _ in (409, nil) }
        guard case .notCommandable = try await refused.assignSchedule(
            channelId: "pi-pwm-0", scheduleId: "6f1e4e2a-1111-4222-8333-444455556666"
        ) else {
            Issue.record("expected .notCommandable")
            return
        }
    }

    @Test("unassign: 404 means nothing was assigned — already the state the operator wanted")
    func unassignNothing() async throws {
        let cleared = stub { _ in (200, json(#"{"unassigned": "6f1e4e2a-1111-4222-8333-444455556666"}"#)) }
        #expect(try await cleared.unassignSchedule(channelId: "pi-pwm-0") == .unassigned)
        let empty = stub { _ in (404, nil) }
        #expect(try await empty.unassignSchedule(channelId: "pi-pwm-0") == .nothingAssigned)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (wrappers do not exist).

- [ ] **Step 3: Implement the wrappers** — new `// MARK: Schedules` section
in `HubClient.swift`, house style throughout (exhaustive switch, documented
non-2xx to outcome cases, `credentialWasRejected()` on 401, undocumented
throws):

```swift
    // MARK: Schedules

    /// The schedule library (`GET /api/v1/lighting/schedules`) — every
    /// curve, with the channels each is assigned to.
    public func schedules() async throws -> [Components.Schemas.ScheduleView] {
        switch try await client.listSchedules() {
        case let .ok(response): return try response.body.json
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the schedules query")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("schedules returned \(statusCode)")
        }
    }

    /// Every documented ending of creating or replacing a schedule. One enum
    /// for both verbs because the editor's Save is one gesture — which verb
    /// ran is not something the operator should need different handling for.
    public enum ScheduleSaveOutcome: Sendable {
        /// 200 — the hub's copy, authoritative (times normalised, id set).
        case saved(Components.Schemas.ScheduleView)
        /// 409 — another schedule already has this name.
        case nameTaken
        /// 422 — the curve does not validate. Description-only on the wire,
        /// so no hub sentence to relay; the editor pre-validates with the
        /// same rules to make this near-unreachable.
        case curveRejected
        /// 404 — update only: the schedule was deleted under the editor.
        case unknownSchedule
    }

    public func createSchedule(
        _ request: Components.Schemas.ScheduleRequest
    ) async throws -> ScheduleSaveOutcome {
        switch try await client.createSchedule(body: .json(request)) {
        case let .ok(response): return .saved(try response.body.json)
        case .conflict: return .nameTaken
        case .unprocessableContent: return .curveRejected
        case .unauthorized: throw credentialWasRejected()
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("createSchedule returned \(statusCode)")
        }
    }

    public func updateSchedule(
        id: String, _ request: Components.Schemas.ScheduleRequest
    ) async throws -> ScheduleSaveOutcome {
        switch try await client.updateSchedule(
            path: .init(scheduleId: id), body: .json(request)
        ) {
        case let .ok(response): return .saved(try response.body.json)
        case .notFound: return .unknownSchedule
        case .conflict: return .nameTaken
        case .unprocessableContent: return .curveRejected
        case .unauthorized: throw credentialWasRejected()
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("updateSchedule returned \(statusCode)")
        }
    }

    /// Every documented ending of `DELETE /api/v1/lighting/schedules/{id}`.
    public enum ScheduleDeleteOutcome: Sendable, Equatable {
        case deleted
        /// 409 — still assigned to a channel; unassign it first (the hub's
        /// ON DELETE RESTRICT, the forgetDevice lesson pre-applied).
        case stillAssigned
        /// 404 — already gone.
        case unknown
    }

    public func deleteSchedule(id: String) async throws -> ScheduleDeleteOutcome {
        switch try await client.deleteSchedule(path: .init(scheduleId: id)) {
        case .noContent: return .deleted
        case .conflict: return .stillAssigned
        case .notFound: return .unknown
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the schedule id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("deleteSchedule returned \(statusCode)")
        }
    }

    /// Every documented ending of pointing a channel at a schedule. Assign
    /// replaces whatever was assigned — one schedule per channel is the
    /// hub's data model, so there is no "already assigned" conflict case.
    public enum AssignOutcome: Sendable {
        /// 200 — echoes the schedule, `assignedChannels` freshly including
        /// this channel.
        case assigned(Components.Schemas.ScheduleView)
        /// 409 — the channel is registered observe_only and accepts no
        /// commands (same meaning as `HoldOutcome.notCommandable`).
        case notCommandable
        /// 404 — the schedule was deleted under the picker.
        case unknownSchedule
    }

    public func assignSchedule(
        channelId: String, scheduleId: String
    ) async throws -> AssignOutcome {
        switch try await client.assignSchedule(
            path: .init(channelId: channelId),
            body: .json(.init(scheduleId: scheduleId))
        ) {
        case let .ok(response): return .assigned(try response.body.json)
        case .conflict: return .notCommandable
        case .notFound: return .unknownSchedule
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the channel id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("assignSchedule returned \(statusCode)")
        }
    }

    /// Every documented ending of clearing a channel's schedule.
    public enum UnassignOutcome: Sendable, Equatable {
        case unassigned
        /// 404 — nothing was assigned; already the state the operator asked
        /// for, so callers treat it as success with different words.
        case nothingAssigned
    }

    public func unassignSchedule(channelId: String) async throws -> UnassignOutcome {
        switch try await client.unassignSchedule(path: .init(channelId: channelId)) {
        case .ok: return .unassigned
        case .notFound: return .nothingAssigned
        case .unauthorized: throw credentialWasRejected()
        case .unprocessableContent:
            throw ClientError.unexpected("the hub rejected the channel id")
        case let .undocumented(statusCode, _):
            throw ClientError.unexpected("unassignSchedule returned \(statusCode)")
        }
    }
```

(Generated inits order labels alphabetically — `ScheduleRequest(anchor:locale:name:points:zone:)`
with defaults omittable, `SchedulePoint(at:duty:)`, `ScheduleAssignRequest(scheduleId:)`.
If Task 1 Step 5 found `id`/`scheduleId` generated as `UUID` rather than
`String`, these signatures keep `String` and convert at the call into the
generated type.)

- [ ] **Step 4: Run the schedule tests — expect PASS.**

- [ ] **Step 5: Commit**

```sh
git add BellasReefKit
git commit -m "feat(kit): HubClient schedule wrappers — library CRUD, assign, unassign

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `ScheduleLibrary` store + `AppModel` wiring (PR 3)

**Files:**
- Create: `BellasReefKit/Sources/BellasReefKit/ScheduleLibrary.swift`
- Modify: `BellasReef/BellasReefApp.swift:60-62` (stored properties),
  `:102-103` (`adopt`), `:153-156` (`credentialRejected`), `:184-187`
  (`unpair`)
- Test: `BellasReefKit/Tests/BellasReefKitTests/ScheduleLibraryTests.swift`

**Interfaces:**
- Consumes: `HubClient` wrappers (Task 5).
- Produces (Tasks 8–10 read `library.schedules`, call the pass-throughs):

```swift
@MainActor @Observable public final class ScheduleLibrary {
    public enum Load: Equatable, Sendable { case idle, loading, loaded, failed(String) }
    public private(set) var state: Load
    public private(set) var schedules: [Components.Schemas.ScheduleView]
    public init(client: HubClient)
    public func refresh() async
    public func schedule(assignedTo channelId: String) -> Components.Schemas.ScheduleView?
    public func create(_ request: Components.Schemas.ScheduleRequest) async throws -> HubClient.ScheduleSaveOutcome
    public func update(id: String, _ request: Components.Schemas.ScheduleRequest) async throws -> HubClient.ScheduleSaveOutcome
    public func delete(id: String) async throws -> HubClient.ScheduleDeleteOutcome
    public func assign(channelId: String, scheduleId: String) async throws -> HubClient.AssignOutcome
    public func unassign(channelId: String) async throws -> HubClient.UnassignOutcome
}
```

- [ ] **Step 1: Write the failing tests** (`ScheduleLibraryTests.swift`, own
`anyHub`/`json`/`stub` copies again; `stub` here returns the `HubClient`,
wrap it in the library):

```swift
@Suite("ScheduleLibrary")
@MainActor
struct ScheduleLibraryTests {

    @Test("refresh loads and sorts by name; failure is its own state with the message kept")
    func refreshStates() async {
        let library = ScheduleLibrary(client: stub { _ in
            (200, json(#"""
                [{"id": "b", "name": "Zebra", "zone": "UTC", "anchor": "clock",
                  "points": [{"at": "08:00:00", "duty": 0.0}, {"at": "20:00:00", "duty": 0.5}],
                  "assigned_channels": []},
                 {"id": "a", "name": "Alpha", "zone": "UTC", "anchor": "clock",
                  "points": [{"at": "08:00:00", "duty": 0.0}, {"at": "20:00:00", "duty": 0.5}],
                  "assigned_channels": ["pi-pwm-0"]}]
                """#))
        })
        await library.refresh()
        #expect(library.state == .loaded)
        #expect(library.schedules.map(\.name) == ["Alpha", "Zebra"])
        #expect(library.schedule(assignedTo: "pi-pwm-0")?.name == "Alpha")
        #expect(library.schedule(assignedTo: "pi-pwm-1") == nil)

        let failing = ScheduleLibrary(client: stub { _ in (500, nil) })
        await failing.refresh()
        guard case .failed = failing.state else {
            Issue.record("expected .failed, got \(failing.state)")
            return
        }
    }

    @Test("a successful mutation re-reads the library — the hub is the authority")
    func mutationRefreshes() async throws {
        let calls = CallCounter()
        let library = ScheduleLibrary(client: stub { operation in
            if operation == "listSchedules" {
                await calls.bump()
                return (200, json("[]"))
            }
            #expect(operation == "deleteSchedule")
            return (204, nil)
        })
        _ = try await library.delete(id: "6f1e4e2a-1111-4222-8333-444455556666")
        #expect(await calls.count == 1)
    }
}

private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `ScheduleLibrary.swift`** (the `DeviceCatalog`
pattern — `DeviceCatalog.swift` is the model, including its logger):

```swift
// Bella's Reef iOS — closed source.

import BellasReefAPI
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.bellasreef.app", category: "schedules")

/// The schedule library, hub-authoritative: every read renders the hub's
/// copy, every successful mutation is followed by a re-read rather than a
/// local patch — the hub normalises times and owns `assigned_channels`, and
/// two clients can edit at once.
///
/// Separate from `DeviceCatalog` for the same reason that is separate from
/// `TankMonitor`: different clock. Schedules change when a person edits
/// them, not when a reading arrives.
@MainActor
@Observable
public final class ScheduleLibrary {

    public enum Load: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var state: Load = .idle
    public private(set) var schedules: [Components.Schemas.ScheduleView] = []

    private let client: HubClient

    public init(client: HubClient) {
        self.client = client
    }

    public func refresh() async {
        if schedules.isEmpty { state = .loading }
        do {
            schedules = try await client.schedules().sorted { $0.name < $1.name }
            state = .loaded
        } catch {
            log.error("could not load schedules: \(String(describing: error))")
            state = .failed("\(error)")
        }
    }

    /// The schedule playing on a channel, if any — `assigned_channels` is
    /// the wire's side of the join, one schedule per channel.
    public func schedule(assignedTo channelId: String) -> Components.Schemas.ScheduleView? {
        schedules.first { $0.assignedChannels.contains(channelId) }
    }

    public func create(
        _ request: Components.Schemas.ScheduleRequest
    ) async throws -> HubClient.ScheduleSaveOutcome {
        let outcome = try await client.createSchedule(request)
        if case .saved = outcome { await refresh() }
        return outcome
    }

    public func update(
        id: String, _ request: Components.Schemas.ScheduleRequest
    ) async throws -> HubClient.ScheduleSaveOutcome {
        let outcome = try await client.updateSchedule(id: id, request)
        if case .saved = outcome { await refresh() }
        return outcome
    }

    public func delete(id: String) async throws -> HubClient.ScheduleDeleteOutcome {
        let outcome = try await client.deleteSchedule(id: id)
        if outcome == .deleted { await refresh() }
        return outcome
    }

    public func assign(
        channelId: String, scheduleId: String
    ) async throws -> HubClient.AssignOutcome {
        let outcome = try await client.assignSchedule(channelId: channelId, scheduleId: scheduleId)
        if case .assigned = outcome { await refresh() }
        return outcome
    }

    public func unassign(channelId: String) async throws -> HubClient.UnassignOutcome {
        let outcome = try await client.unassignSchedule(channelId: channelId)
        if outcome == .unassigned { await refresh() }
        return outcome
    }
}
```

- [ ] **Step 4: Run the library tests — expect PASS.**

- [ ] **Step 5: Wire into `AppModel`** (`BellasReefApp.swift`): add
`private(set) var library: ScheduleLibrary?` beside `catalog` (line 62); in
`adopt` add `self.library = ScheduleLibrary(client: client)` beside the
catalog creation (line 102-103); in `credentialRejected()` and `unpair()` add
`library = nil` beside `catalog = nil` (lines 156, 186).

- [ ] **Step 6: App build — expect green. Commit**

```sh
git add BellasReefKit BellasReef
git commit -m "feat(kit): ScheduleLibrary store — hub-authoritative schedule state

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `lightingCards` learns its schedule (PR 3)

**Files:**
- Modify: `BellasReefKit/Sources/BellasReefKit/LightingCards.swift:51-106`
- Test: `BellasReefKit/Tests/BellasReefKitTests/LightingCardsTests.swift`

**Interfaces:**
- Consumes: `ScheduleCurve` (Task 4), `Components.Schemas.ScheduleView`.
- Produces (Tasks 8, 10 read these):

```swift
// on LightingCard:
public struct AssignedSchedule: Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let curve: ScheduleCurve
    public init(id: String, name: String, curve: ScheduleCurve)
}
public let schedule: AssignedSchedule?   // new stored property, last init param

public func lightingCards(
    devices: [Components.Schemas.DeviceView],
    frames: [String: Components.Schemas.StateFrame],
    schedules: [Components.Schemas.ScheduleView] = []
) -> [LightingCard]
```

The default `schedules: []` keeps every existing call site and fixture
compiling; `LightingCard.init` gains `schedule: AssignedSchedule? = nil` as a
defaulted last parameter for the same reason.

- [ ] **Step 1: Write the failing tests** (append to `LightingCardsTests`,
reusing its `LightingFixtures`):

```swift
    private func scheduleView(
        name: String, assignedTo channels: [String], zone: String = "UTC",
        points: [Components.Schemas.SchedulePoint] = [
            .init(at: "08:00:00", duty: 0.0), .init(at: "20:00:00", duty: 0.6),
        ]
    ) -> Components.Schemas.ScheduleView {
        .init(
            anchor: .clock, assignedChannels: channels,
            id: "id-\(name)", name: name, points: points, zone: zone
        )
    }

    @Test("a card carries the schedule assigned to its channel")
    func scheduleAttaches() {
        let cards = lightingCards(
            devices: [LightingFixtures.device(id: "pi-pwm-0")],
            frames: [:],
            schedules: [scheduleView(name: "Reef day", assignedTo: ["pi-pwm-0"])]
        )
        #expect(cards[0].schedule?.name == "Reef day")
        #expect(cards[0].schedule?.curve.points.count == 2)
    }

    @Test("no assignment, no schedule — and an unparseable one renders as absent, not as a guess")
    func scheduleAbsentOrUnreadable() {
        let unassigned = lightingCards(
            devices: [LightingFixtures.device(id: "pi-pwm-0")],
            frames: [:],
            schedules: [scheduleView(name: "Reef day", assignedTo: ["pi-pwm-1"])]
        )
        #expect(unassigned[0].schedule == nil)

        let badZone = lightingCards(
            devices: [LightingFixtures.device(id: "pi-pwm-0")],
            frames: [:],
            schedules: [scheduleView(name: "Reef day", assignedTo: ["pi-pwm-0"], zone: "Neptune/Trench")]
        )
        #expect(badZone[0].schedule == nil)
    }
```

(If `LightingFixtures.device` takes different labels, keep the fixture's own
signature — the only requirement is `deviceId: "pi-pwm-0"`, adopted, role
`light`. If `ScheduleView.id` turned out to be `UUID` in Task 1 Step 5, build
the fixture with a `UUID()` and assert on `name` only.)

- [ ] **Step 2: Run — expect FAIL** (no `schedules:` parameter).

- [ ] **Step 3: Implement in `LightingCards.swift`**

Add inside `LightingCard`, after `ActiveHold`:

```swift
    /// The curve this channel is playing, when one is assigned — id and
    /// name straight off the wire, the points parsed into `ScheduleCurve`.
    /// `nil` covers both no-assignment and a schedule this client could not
    /// parse (unknown zone, malformed time): absent renders honestly, a
    /// guessed curve would not.
    public struct AssignedSchedule: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let curve: ScheduleCurve

        public init(id: String, name: String, curve: ScheduleCurve) {
            self.id = id
            self.name = name
            self.curve = curve
        }
    }
```

Add `public let schedule: AssignedSchedule?` after `maxRuntimeS`, extend the
memberwise `init` with `schedule: AssignedSchedule? = nil` as the last
parameter, and extend `lightingCards`:

```swift
public func lightingCards(
    devices: [Components.Schemas.DeviceView],
    frames: [String: Components.Schemas.StateFrame],
    schedules: [Components.Schemas.ScheduleView] = []
) -> [LightingCard] {
    devices
        .filter { $0.adopted == true && $0.role == "light" }
        .map { device in
            let frame = frames[device.deviceId]
            let assigned = schedules.first { $0.assignedChannels.contains(device.deviceId) }
            return LightingCard(
                id: device.deviceId,
                name: device.displayName ?? device.deviceId,
                reportedDuty: frame.map(reportedDuty(from:)),
                hold: frame?.override.map {
                    LightingCard.ActiveHold(
                        id: $0.id, duty: $0.duty, expiresAt: $0.expiresAt,
                        transition: HubClient.HoldTransition($0.transition)
                    )
                },
                maxRuntimeS: device.maxRuntimeS,
                schedule: assigned.flatMap { schedule in
                    ScheduleCurve(schedule).map {
                        LightingCard.AssignedSchedule(id: schedule.id, name: schedule.name, curve: $0)
                    }
                }
            )
        }
        .sorted { $0.id < $1.id }
}
```

- [ ] **Step 4: Run the full LightingCards suite — expect PASS** (old tests
untouched by the defaulted parameter).

- [ ] **Step 5: Commit**

```sh
git add BellasReefKit
git commit -m "feat(kit): lighting cards carry their assigned schedule's curve

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Lighting card — mini day-curve, now dot, returns-to (PR 3)

**Files:**
- Create: `BellasReef/Views/MiniDayCurve.swift`
- Modify: `BellasReef/Views/LightingView.swift:42-97` (`content` — pass
  schedules, load library), `:258-300` (card body — curve block between
  header and hold row; "returns to" in the hold label)

**Interfaces:**
- Consumes: `LightingCard.schedule` (Task 7), `model.library` (Task 6).
- Produces: `struct MiniDayCurve: View { init(curve: ScheduleCurve, nowSeconds: Int, nowDuty: Double?) }`
  — Task 10's detail screen does *not* reuse it (detail uses Swift Charts);
  it exists for the card only, matching `Sparkline`'s idiom
  (`TankView.swift:519-541`).

- [ ] **Step 1: Implement `MiniDayCurve.swift`**

```swift
// Bella's Reef iOS — closed source.

import BellasReefKit
import SwiftUI

/// The card's day-at-a-glance: the assigned curve midnight-to-midnight as a
/// `Path` (the `Sparkline` idiom — Charts stays on the detail and History
/// screens), with a now dot plotted at the *wire* duty, not the curve's own
/// value. When the two diverge — a hold, a slew still in flight, the <8%
/// snap — the dot visibly leaves the line, which is exactly the information
/// (spec 2026-08-19 §iOS item 1). No frame yet, no dot.
struct MiniDayCurve: View {
    let curve: ScheduleCurve
    /// Seconds since local midnight in the schedule's zone
    /// (`curve.secondsOfDay(for:)` at the caller's tick).
    let nowSeconds: Int
    /// The hub's reported duty — wire truth. `nil` while the stream has not
    /// spoken for this channel.
    let nowDuty: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let plotted = curve.plotPoints
            Path { path in
                for (index, point) in plotted.enumerated() {
                    let x = width * CGFloat(point.seconds) / 86_400
                    let y = height * (1 - CGFloat(point.duty))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Theme.accent.opacity(0.5), lineWidth: 1.5)

            if let nowDuty {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
                    .position(
                        x: width * CGFloat(nowSeconds) / 86_400,
                        y: height * (1 - CGFloat(nowDuty))
                    )
            }
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let scheduled = Int((curve.duty(atSecondsToday: nowSeconds) * 100).rounded())
        if let nowDuty {
            return "Day curve. Scheduled \(scheduled) percent now, actual \(Int((nowDuty * 100).rounded())) percent."
        }
        return "Day curve. Scheduled \(scheduled) percent now."
    }
}
```

This needs one small public addition to `ScheduleCurve` (add in Task 8, with
a one-line test in `ScheduleCurveTests`): 

```swift
    /// Duty at a bare seconds-of-day — for callers that already computed
    /// "now" in the schedule's zone (the card computes it once and uses it
    /// for both the dot's x and this label).
    public func duty(atSecondsToday seconds: Int) -> Double {
        duty(atSecondsOfDay: seconds)
    }
```

- [ ] **Step 2: Feed schedules into the cards** — in `LightingView.content`
(line 42-47): change the signature to
`content(monitor: TankMonitor, catalog: DeviceCatalog, library: ScheduleLibrary)`,
update the caller at line 23-24 to unwrap `model.library` alongside the other
two, and build cards as:

```swift
        let cards = lightingCards(
            devices: catalog.devices, frames: monitor.channels, schedules: library.schedules
        )
```

Extend the existing `.task`/`.refreshable`/`.onChange(of: scenePhase)`
blocks (lines 86-96) to also `await library.refresh()` wherever
`catalog.refresh()` runs.

- [ ] **Step 3: The card's curve block** — in `LightingCardView.body`
(line 258), insert between the header `HStack` (ends line 268) and the hold
`TimelineView` (line 270):

```swift
            if let schedule = card.schedule {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    MiniDayCurve(
                        curve: schedule.curve,
                        nowSeconds: schedule.curve.secondsOfDay(for: context.date),
                        nowDuty: card.reportedDuty
                    )
                }
                Text(schedule.name)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                // Absence is a state, not a blank: with nothing assigned the
                // engine rests this channel dark (composition law — resting
                // is the schedule's value, else SAFE_DUTY).
                Text("No schedule — resting is off.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
```

- [ ] **Step 4: "Returns to N %"** — the hold row's `Label` (line 281)
gains the curve's answer for the hold's expiry. Replace the label title with:

```swift
                        Label(
                            "Held at \(Int(hold.duty * 100))% · \(Self.label(for: hold.transition)) · "
                                + "\(formatRemaining(secondsRemaining(hold, now: context.date)))"
                                + returnsToText(hold),
                            systemImage: "hand.raised.fill"
                        )
```

and add beside the card's other private helpers:

```swift
    /// What release/expiry goes back to — computable now that resting has a
    /// value (spec 2026-08-19: "returns to N %" from the curve at expiry).
    /// Silent with no schedule: "returns to off" is already what the layout
    /// says one line up, and repeating it in every hold row is noise.
    private func returnsToText(_ hold: LightingCard.ActiveHold) -> String {
        guard let schedule = card.schedule else { return "" }
        let duty = schedule.curve.duty(at: hold.expiresAt)
        return " · returns to \(Int((duty * 100).rounded()))%"
    }
```

- [ ] **Step 5: Build + full kit tests — expect green.** In the simulator
(app build command, then run), the Lighting tab shows: card with no schedule
→ "No schedule — resting is off."; nothing else changed visually.

- [ ] **Step 6: Commit**

```sh
git add BellasReef BellasReefKit
git commit -m "feat(lighting): card mini day-curve with a now dot at the wire duty

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Schedules screen — library + editor (PR 3)

**Files:**
- Create: `BellasReef/Views/ScheduleChart.swift`
- Create: `BellasReef/Views/SchedulesView.swift`
- Create: `BellasReef/Views/ScheduleEditorView.swift`
- Modify: `BellasReef/Views/LightingView.swift` (toolbar entry into the
  library)

**Interfaces:**
- Consumes: `ScheduleLibrary` (Task 6), `ScheduleCurve` (Task 4),
  `DeviceCatalog.devices` (adopted lights for the multi-select).
- Produces: `struct SchedulesView: View` (pushed from the Lighting tab's
  toolbar); `struct ScheduleEditorView: View { init(schedule: Components.Schemas.ScheduleView?) }`
  (`nil` = create) — Task 10 links a light's assigned schedule to the same
  editor; `struct ScheduleChart: View { init(curve: ScheduleCurve, nowDate: Date?) }`
  — the editor preview passes `nowDate: nil`, Task 10's detail passes the
  tick date.

- [ ] **Step 1: `ScheduleChart.swift`** (the Swift Charts block —
`HistoryView.swift:243-441` is the house model for axis/scale/plot styling):

```swift
// Bella's Reef iOS — closed source.

import BellasReefKit
import Charts
import SwiftUI

/// One schedule, midnight to midnight (spec 2026-08-19 §iOS item 2):
/// the interpolated line, the real points marked, and — when `nowDate` is
/// given — a vertical now line. Read-only; editing is the points list.
struct ScheduleChart: View {
    let curve: ScheduleCurve
    /// `nil` on the editor preview: a draft has no meaningful "now".
    let nowDate: Date?

    var body: some View {
        Chart {
            ForEach(curve.plotPoints, id: \.seconds) { point in
                LineMark(
                    x: .value("Hour", Double(point.seconds) / 3600),
                    y: .value("Brightness", point.duty * 100)
                )
                .foregroundStyle(Theme.accent)
            }
            ForEach(curve.points, id: \.seconds) { point in
                PointMark(
                    x: .value("Hour", Double(point.seconds) / 3600),
                    y: .value("Brightness", point.duty * 100)
                )
                .foregroundStyle(Theme.accent)
            }
            if let nowDate {
                RuleMark(x: .value("Now", Double(curve.secondsOfDay(for: nowDate)) / 3600))
                    .foregroundStyle(Theme.attention.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hour = value.as(Double.self) {
                        Text("\(Int(hour)):00")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))%")
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: `SchedulesView.swift`**

```swift
// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// The schedule library (spec 2026-08-19 §iOS item 3): every curve on the
/// hub, create / edit / delete. Assignment lives inside the editor (channel
/// multi-select) and on the light detail (schedule picker) — this list just
/// says which lights each curve is playing on.
struct SchedulesView: View {
    @Environment(AppModel.self) private var model

    @State private var creating = false
    @State private var confirmingDelete: Components.Schemas.ScheduleView?
    @State private var problem: String?

    var body: some View {
        Group {
            if let library = model.library {
                content(library: library)
            } else {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "wifi.slash",
                    description: Text("Reopen the app, or re-pair from the System tab.")
                )
            }
        }
        .reefBackground()
        .navigationTitle("Schedules")
        .toolbar {
            Button {
                creating = true
            } label: {
                Label("New schedule", systemImage: "plus")
            }
            .accessibilityIdentifier("schedules-create")
        }
        .sheet(isPresented: $creating) {
            NavigationStack { ScheduleEditorView(schedule: nil) }
        }
    }

    @ViewBuilder
    private func content(library: ScheduleLibrary) -> some View {
        List {
            switch library.state {
            case .idle, .loading:
                Text("Loading schedules…")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 10) {
                    Label("Could not load the schedule library", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.attention)
                    Text(message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                    Button("Try again") { Task { await library.refresh() } }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }
            case .loaded:
                if library.schedules.isEmpty {
                    Text("No schedules yet. A schedule is a day curve — points of "
                         + "time and brightness — that assigned lights follow.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(library.schedules, id: \.id) { schedule in
                    NavigationLink {
                        ScheduleEditorView(schedule: schedule)
                    } label: {
                        row(schedule)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            confirmingDelete = schedule
                        }
                    }
                }
                if let problem {
                    Text(problem)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.attention)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await library.refresh() }
        .task { await library.refresh() }
        .confirmationDialog(
            "Delete this schedule?",
            isPresented: .init(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            presenting: confirmingDelete
        ) { schedule in
            Button("Delete \(schedule.name)", role: .destructive) {
                Task { await delete(schedule, library: library) }
            }
        } message: { schedule in
            Text(schedule.assignedChannels.isEmpty
                 ? "The curve is deleted for good."
                 : "It is playing on \(schedule.assignedChannels.count) light(s); the hub will refuse until it is unassigned.")
        }
    }

    private func row(_ schedule: Components.Schemas.ScheduleView) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(schedule.name)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.primaryText)
            Text("\(schedule.points.count) points · "
                 + (schedule.assignedChannels.isEmpty
                    ? "not assigned"
                    : "on \(schedule.assignedChannels.count) light(s)"))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func delete(
        _ schedule: Components.Schemas.ScheduleView, library: ScheduleLibrary
    ) async {
        problem = nil
        do {
            switch try await library.delete(id: schedule.id) {
            case .deleted, .unknown: break
            case .stillAssigned:
                problem = "\(schedule.name) is still assigned — unassign it from its lights first."
            }
        } catch {
            problem = HumanError.describe(error)
        }
    }
}
```

- [ ] **Step 3: `ScheduleEditorView.swift`**

```swift
// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// Create or edit one schedule (spec 2026-08-19 §iOS item 3): a read-only
/// chart preview above a points list — time-wheel + duty field rows, add,
/// swipe to delete — and Save PUTs the whole curve. Nobody drags the curve;
/// Kessil is the category norm and the research said so.
///
/// The curve is pre-validated client-side with the hub's own `validate_curve`
/// rules (≥2 points, strictly ascending unique times, duty 0–100%): the wire
/// 422 is description-only, so the only good error message is the one that
/// prevents the request.
struct ScheduleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// `nil` creates. Captured once — the editor edits a local draft and the
    /// hub's copy only moves on Save.
    let schedule: Components.Schemas.ScheduleView?

    private struct DraftPoint: Identifiable {
        let id = UUID()
        var seconds: Int
        var dutyPercentText: String

        var duty: Double? {
            guard let percent = Double(dutyPercentText), (0...100).contains(percent)
            else { return nil }
            return percent / 100
        }
    }

    @State private var name: String
    @State private var draft: [DraftPoint]
    @State private var submitting = false
    @State private var problem: String?

    init(schedule: Components.Schemas.ScheduleView?) {
        self.schedule = schedule
        _name = State(initialValue: schedule?.name ?? "")
        // A new schedule starts as an editable dawn-to-dusk template rather
        // than an empty list two mandatory adds away from valid.
        let points: [DraftPoint] = schedule.map {
            $0.points.map { point in
                DraftPoint(
                    seconds: ScheduleCurve.seconds(fromWireTime: point.at) ?? 0,
                    dutyPercentText: String(Int((point.duty * 100).rounded()))
                )
            }
        } ?? [
            DraftPoint(seconds: 8 * 3600, dutyPercentText: "0"),
            DraftPoint(seconds: 10 * 3600, dutyPercentText: "60"),
            DraftPoint(seconds: 18 * 3600, dutyPercentText: "60"),
            DraftPoint(seconds: 20 * 3600, dutyPercentText: "0"),
        ]
        _draft = State(initialValue: points)
    }

    /// The draft as a curve, when it validates — drives both the preview and
    /// the Save button.
    private var draftCurve: ScheduleCurve? {
        let sorted = draft.sorted { $0.seconds < $1.seconds }
        let points = sorted.compactMap { point -> ScheduleCurve.Point? in
            point.duty.map { ScheduleCurve.Point(seconds: point.seconds, duty: $0) }
        }
        guard points.count == draft.count else { return nil }
        return ScheduleCurve(
            points: points,
            zoneIdentifier: schedule?.zone ?? TimeZone.current.identifier
        )
    }

    private var validationText: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The schedule needs a name." }
        if draft.contains(where: { $0.duty == nil }) { return "Brightness is 0–100%." }
        let times = draft.map(\.seconds)
        if Set(times).count != times.count { return "Two points share a time." }
        if draft.count < 2 { return "A curve needs at least two points." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                if let curve = draftCurve {
                    ScheduleChart(curve: curve, nowDate: nil)
                        .frame(height: 160)
                        .listRowBackground(Color.clear)
                }
            }

            Section("Name") {
                TextField("Schedule name", text: $name)
                    .accessibilityIdentifier("schedule-name")
            }

            Section("Points") {
                ForEach($draft) { $point in
                    HStack {
                        DatePicker(
                            "Time",
                            selection: timeBinding($point),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        Spacer()
                        TextField("%", text: $point.dutyPercentText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("%")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .onDelete { offsets in
                    draft.remove(atOffsets: offsets)
                }
                Button {
                    addPoint()
                } label: {
                    Label("Add point", systemImage: "plus")
                }
            }

            if let assigned = schedule {
                assignSection(assigned)
            } else {
                Section {
                    EmptyView()
                } footer: {
                    Text("Save first, then assign lights to it.")
                }
            }

            if let validationText {
                Text(validationText)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            }
            if let problem {
                Text(problem)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            }
        }
        .scrollContentBackground(.hidden)
        .reefBackground()
        .navigationTitle(schedule == nil ? "New Schedule" : "Edit Schedule")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(submitting || validationText != nil)
                    .accessibilityIdentifier("schedule-save")
            }
            if schedule == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// DatePicker wants a Date; the draft keeps seconds-of-day. Anchored to
    /// today in the device zone — only the hour and minute survive the trip
    /// back, and the wire second is always :00.
    private func timeBinding(_ point: Binding<DraftPoint>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: point.wrappedValue.seconds / 3600,
                    minute: point.wrappedValue.seconds % 3600 / 60,
                    second: 0, of: Calendar.current.startOfDay(for: Date())
                ) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                point.wrappedValue.seconds = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60
            }
        )
    }

    /// A new point lands an hour after the latest, wrapping before midnight
    /// — a deterministic spot the operator immediately re-picks anyway.
    private func addPoint() {
        let latest = draft.map(\.seconds).max() ?? 0
        let seconds = min(latest + 3600, 86_340)
        draft.append(DraftPoint(seconds: seconds, dutyPercentText: "0"))
    }

    private func save() async {
        guard let library = model.library else { return }
        submitting = true
        defer { submitting = false }
        problem = nil
        let sorted = draft.sorted { $0.seconds < $1.seconds }
        let request = Components.Schemas.ScheduleRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            points: sorted.map {
                .init(at: ScheduleCurve.wireTime(fromSeconds: $0.seconds), duty: $0.duty ?? 0)
            },
            zone: schedule?.zone ?? TimeZone.current.identifier
        )
        do {
            let outcome: HubClient.ScheduleSaveOutcome
            if let schedule {
                outcome = try await library.update(id: schedule.id, request)
            } else {
                outcome = try await library.create(request)
            }
            switch outcome {
            case .saved:
                dismiss()
            case .nameTaken:
                problem = "A schedule with that name already exists."
            case .curveRejected:
                problem = "The hub rejected the curve."
            case .unknownSchedule:
                problem = "This schedule was deleted on another device."
            }
        } catch {
            problem = HumanError.describe(error)
        }
    }

    /// Channel multi-select (spec: "Assign = channel multi-select on the
    /// schedule"). Toggling talks to the hub immediately — assignment is not
    /// part of the curve draft, and the hub is its authority.
    @ViewBuilder
    private func assignSection(_ schedule: Components.Schemas.ScheduleView) -> some View {
        let lights = (model.catalog?.devices ?? [])
            .filter { $0.adopted == true && $0.role == "light" }
            .sorted { $0.deviceId < $1.deviceId }
        Section("Assigned lights") {
            if lights.isEmpty {
                Text("No lights adopted — adopt a PWM channel under System.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(lights, id: \.deviceId) { light in
                let current = model.library?.schedule(assignedTo: light.deviceId)
                let isThis = current?.id == schedule.id
                Button {
                    Task { await toggle(light.deviceId, schedule: schedule, currentlyThis: isThis) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(light.displayName ?? light.deviceId)
                                .foregroundStyle(Theme.primaryText)
                            if let current, !isThis {
                                Text("Now on \(current.name) — selecting moves it.")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Spacer()
                        if isThis {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(submitting)
            }
        }
    }

    private func toggle(
        _ channelId: String, schedule: Components.Schemas.ScheduleView, currentlyThis: Bool
    ) async {
        guard let library = model.library else { return }
        submitting = true
        defer { submitting = false }
        problem = nil
        do {
            if currentlyThis {
                _ = try await library.unassign(channelId: channelId)
            } else {
                switch try await library.assign(channelId: channelId, scheduleId: schedule.id) {
                case .assigned: break
                case .notCommandable:
                    problem = "That channel is observe-only — it accepts no commands."
                case .unknownSchedule:
                    problem = "This schedule was deleted on another device."
                }
            }
        } catch {
            problem = HumanError.describe(error)
        }
    }
}
```

- [ ] **Step 4: Toolbar entry** — in `LightingView.body` (line 34, after
`.navigationTitle("Lighting")`):

```swift
            .toolbar {
                NavigationLink {
                    SchedulesView()
                } label: {
                    Label("Schedules", systemImage: "calendar.badge.clock")
                }
                .accessibilityIdentifier("lighting-schedules")
            }
```

- [ ] **Step 5: Build + run in the simulator.** Create a schedule against
the live hub is a bench step (David); in the sim without a hub the library
renders its failed state with retry. Verify: editor validation text reacts
(duplicate time, empty name, out-of-range duty); Save disabled while invalid.

- [ ] **Step 6: Commit**

```sh
git add BellasReef
git commit -m "feat(lighting): schedule library and editor — chart preview, points list, assignment

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Light detail — full curve, now line, schedule picker (PR 3)

**Files:**
- Create: `BellasReef/Views/LightDetailView.swift`
- Modify: `BellasReef/Views/LightingView.swift` (card header →
  NavigationLink by id; `navigationDestination`)

**Interfaces:**
- Consumes: `LightingCard` (Task 7), `ScheduleLibrary` (Task 6),
  `ScheduleCurve.plotPoints` / `nextPoint(after:)` (Task 4).
- Consumes also: `ScheduleChart` (Task 9).
- Produces: `struct LightDetailView: View { init(cardId: String) }`.

- [ ] **Step 1: `LightDetailView.swift`**

```swift
// Bella's Reef iOS — closed source.

import BellasReefAPI
import BellasReefKit
import SwiftUI

/// One light's day (spec 2026-08-19 §iOS item 2): the full curve with a now
/// line, the schedule's name, the next transition — and the schedule picker,
/// the light-side mirror of the editor's channel multi-select. Resolved live
/// from the model by id, not from a card snapshot frozen at tap time: the
/// wire keeps moving while this screen is up.
struct LightDetailView: View {
    @Environment(AppModel.self) private var model

    let cardId: String

    @State private var submitting = false
    @State private var problem: String?

    /// The same merge the Lighting tab renders from — one function, so the
    /// two screens can never disagree about what is assigned.
    private var card: LightingCard? {
        guard let monitor = model.monitor, let catalog = model.catalog else { return nil }
        return lightingCards(
            devices: catalog.devices, frames: monitor.channels,
            schedules: model.library?.schedules ?? []
        ).first { $0.id == cardId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let card {
                    if let schedule = card.schedule {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(alignment: .leading, spacing: 8) {
                                ScheduleChart(curve: schedule.curve, nowDate: context.date)
                                    .frame(height: 200)
                                Text(schedule.name)
                                    .font(Theme.sectionTitle)
                                    .foregroundStyle(Theme.primaryText)
                                Text(nextTransitionText(schedule.curve, now: context.date))
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    } else {
                        Text("No schedule — resting is off.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    pickerSection(card)
                    if let problem {
                        Text(problem)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.attention)
                    }
                } else {
                    ContentUnavailableView(
                        "Light not found",
                        systemImage: "lightbulb.slash",
                        description: Text("It may have been unadopted on another device.")
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .reefBackground()
        .navigationTitle(card?.name ?? cardId)
        .task { await model.library?.refresh() }
    }

    /// "35% at 19:00" — the next anchor the curve reaches, in the
    /// schedule's own zone (the point's time is already local to it).
    private func nextTransitionText(_ curve: ScheduleCurve, now: Date) -> String {
        let next = curve.nextPoint(after: now)
        let time = ScheduleCurve.wireTime(fromSeconds: next.seconds).prefix(5)
        return "\(Int((next.duty * 100).rounded()))% at \(time)"
    }

    @ViewBuilder
    private func pickerSection(_ card: LightingCard) -> some View {
        if let library = model.library {
            VStack(alignment: .leading, spacing: 8) {
                Text("Schedule")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                Picker("Schedule", selection: pickerBinding(card, library: library)) {
                    Text("None").tag(String?.none)
                    ForEach(library.schedules, id: \.id) { schedule in
                        Text(schedule.name).tag(String?.some(schedule.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(submitting)
                .accessibilityIdentifier("light-schedule-picker")
            }
        }
    }

    private func pickerBinding(
        _ card: LightingCard, library: ScheduleLibrary
    ) -> Binding<String?> {
        Binding(
            get: { card.schedule?.id },
            set: { chosen in
                Task { await repoint(card, to: chosen, library: library) }
            }
        )
    }

    private func repoint(
        _ card: LightingCard, to scheduleId: String?, library: ScheduleLibrary
    ) async {
        submitting = true
        defer { submitting = false }
        problem = nil
        do {
            if let scheduleId {
                switch try await library.assign(channelId: card.id, scheduleId: scheduleId) {
                case .assigned: break
                case .notCommandable:
                    problem = "This channel is observe-only — it accepts no commands."
                case .unknownSchedule:
                    problem = "That schedule was deleted on another device."
                }
            } else {
                _ = try await library.unassign(channelId: card.id)
            }
        } catch {
            problem = HumanError.describe(error)
        }
    }
}
```

- [ ] **Step 2: Navigate from the card** — in `LightingView`:

In `content(monitor:catalog:library:)`, add after the `ForEach` block's
closing (around line 63):

```swift
        // By id, not by card value: the destination re-resolves the card
        // live, so a frame arriving while the detail is up updates it.
        .navigationDestination(for: String.self) { id in
            LightDetailView(cardId: id)
        }
```

(attach the modifier to the `ScrollView`.) In `LightingCardView.body`
(line 260-266), wrap the name in a `NavigationLink`:

```swift
            HStack(alignment: .top) {
                NavigationLink(value: card.id) {
                    HStack(spacing: 4) {
                        Text(card.name)
                            .font(Theme.sectionTitle)
                            .foregroundStyle(Theme.primaryText)
                        Image(systemName: "chevron.right")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lighting-detail-\(card.id)")
                Spacer()
                truthLine
            }
```

- [ ] **Step 3: Build + full kit tests + sim run — expect green.** Verify
navigation: card name → detail; detail picker lists library entries; toolbar
→ Schedules; editor preview chart renders for the template draft.

- [ ] **Step 4: Commit**

```sh
git add BellasReef
git commit -m "feat(lighting): light detail — full day curve, now line, schedule picker

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: Final verification + PR 3 (PR 3)

**Files:** none new.

- [ ] **Step 1: Full gate** — kit tests, then `xcodegen generate` + app
build (Global Constraints commands). Expected: all green.

- [ ] **Step 2: Fixture/regression sweep** — run the *entire*
`BellasReefKitTests` (no `-only-testing`) and confirm the pre-existing suites
(LightingCards, ChannelGroups, Overrides, Pairing, FrameDecoding, Equipment)
still pass with the widened signatures.

- [ ] **Step 3: Push and open PR 3**

```sh
git push -u origin feat/lighting-schedules-ui
gh pr create --title "feat(lighting): schedules UI — card mini-curve, light detail, library editor" \
  --body "<summary of Tasks 4-10>

Decisions for David (also flagged in-plan):
- Schedules created from the app send zone = the device's current IANA zone, not the server default UTC — the times typed are wall-clock times. Say the word and it becomes a visible editor field instead.
- The editor pre-validates curves client-side (hub's validate_curve rules) because the wire 422 is description-only.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 4: Bench handoff note in the PR** — the on-hardware acceptance
(backend spec §Testing) is David's: assign a schedule to `pi-pwm-0` from the
app, watch the wire duty track the curve, meter one point (Stage-2 method,
same probe point — pin 32). The 8% snap is exercised by any dawn/dusk
crossing. The app-side check: the card's now dot sits on the curve when
nothing is held, leaves it during a hold, and "returns to N %" matches the
curve at expiry.

---

## Self-review notes (already applied)

- **Spec coverage:** §iOS item 1 (card mini-curve + now dot at wire duty,
  hold "returns to N %") → Tasks 7–8; item 2 (light detail: full curve,
  points marked, now line, schedule name, next transition) → Task 10; item 3
  (library list, create/rename/delete, editor with chart preview + points
  list + time-wheel + duty field + swipe delete + whole-curve PUT, assign
  both directions) → Tasks 9–10 (rename = the editor's name field on PUT);
  chip-state spec §iOS (header second line, exact copy shapes, `not
  initialised — no channel adopted`, no new screen, optional `state` on
  `Group`) → Tasks 2–3; re-pin → Task 1.
- **Out of scope, per the specs:** drag-to-edit points, on-tank preview, D2
  Live Activity, a "refresh chip" button, any change to what `initialise()`
  writes, solar/lunar anchors (the app always sends `anchor: clock` by
  omitting it — the generated default).
- **Type consistency:** `ScheduleCurve.Point(seconds:duty:)` used in Tasks
  4, 8, 9, 10; `AssignedSchedule(id:name:curve:)` in 7, 8, 10;
  `ScheduleSaveOutcome`/`AssignOutcome`/`UnassignOutcome` names identical in
  Tasks 5, 6, 9, 10; `chipStates` (not `hardware`) is the SystemView state
  name to avoid the `loadEverything()` local. `duty(atSecondsToday:)` is
  added in Task 8 and used only there.
- **Known unknowns, all fenced:** generated names verified in Task 1 Step 5
  with named fallback instructions in Tasks 2, 3, 5, 7.
