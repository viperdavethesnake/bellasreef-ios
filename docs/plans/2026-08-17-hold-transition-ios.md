# Hold Transition (Snap | Ramp) — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Lighting tab lets the operator choose, per hold, whether the light **snaps** to the level (one step) or **ramps** to it (the hub's global slew), and shows that choice on the active hold.

**Architecture:** Re-pin the vendored contracts to backend 3.8.0 (the generated client grows `transition` on `OverrideRequest`/`OverrideView`/`OverrideContext` — no hand-written bindings). One kit-level enum `HoldTransition` wraps the generated payload; `HubClient.hold(...)` sends it; `LightingCard.ActiveHold` carries it off the frame; `LightingView` gets a segmented Snap | Ramp control beside Hold, persisted in `@AppStorage`, and the active-hold row reads "Held at X% · Snap · 28 min".

**Tech Stack:** Swift/SwiftUI, iOS 26+, swift-testing kit tests, xcodegen + xcodebuild on the iPhone 17 sim (UDID `9438872C-7EF2-4BA7-837F-1C55F938E6DF`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).

**Spec:** backend repo `/Users/david/visualstudio/bellasreef/docs/superpowers/specs/2026-08-17-hold-transition-design.md` §Client. Backend shipped as PR #42 (`91742b8`, contracts 3.8.0), deployed 2026-08-17 — the hub already accepts and echoes `transition`.

## Global Constraints

- **No hand-written bindings.** `BellasReefKit/Sources/BellasReefAPI` is generated; the only change there is the re-pinned `openapi.json`. `Contracts/openapi.json` and `BellasReefKit/Sources/BellasReefAPI/openapi.json` must stay byte-identical (CI "Contracts are in sync").
- Re-pin ONLY via `./scripts/pin-contracts.sh 32085994939` (the backend's green main run for `91742b8`); update `Contracts/PINNED.md` (backend commit `91742b8`, contracts 3.8.0, pinned 2026-08-17, plus a "What 3.7.0 → 3.8.0 added" section).
- Wire values: `transition` is `"snap"` or `"ramp"`; server default when omitted is `ramp`. The app ALWAYS sends it explicitly.
- UX rules from the spec: segmented control **Snap | Ramp** beside Hold; choice persists in `@AppStorage` key `lighting.holdTransition`; first-run default **`snap`**; the active-hold row shows the transition. Nothing else on the Lighting tab moves (slider, duration menu, Release, footnote copy unchanged). Design-brief laws still apply: amber errors via `HumanError.describe`, 44 pt touch targets, accessibility identifiers on new controls (`lighting-transition-<card.id>`).
- Kit tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -scheme BellasReefKit-Package -destination 'platform=iOS Simulator,id=9438872C-7EF2-4BA7-837F-1C55F938E6DF' -skipPackagePluginValidation` (run from `BellasReefKit/`; plain `swift test` is broken in this sandbox, pre-existing). App build: `xcodegen generate && xcodebuild build -project BellasReef.xcodeproj -scheme BellasReef -destination 'platform=iOS Simulator,id=9438872C-7EF2-4BA7-837F-1C55F938E6DF' -skipPackagePluginValidation`. Green + no new warnings before every commit.
- Conventional commits with trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Branch `feat/hold-transition` (create from `main` at `05bea03`). No `git push` from an implementer.
- Names used across tasks: `HoldTransition` (kit enum, `String` raw values `snap`/`ramp`), `HubClient.hold(target:duty:durationS:reason:transition:)`, `LightingCard.ActiveHold.transition: HoldTransition`, `LightingFixtures.override(id:duty:expiresInS:transition:)`.

---

## File map

| File | Change |
|---|---|
| `Contracts/openapi.json`, `Contracts/stream-frames.schema.json`, `BellasReefKit/Sources/BellasReefAPI/openapi.json` | re-pinned by script |
| `Contracts/PINNED.md` | pin table + 3.7.0 → 3.8.0 section |
| `BellasReefKit/Sources/BellasReefKit/HubClient.swift` | `HoldTransition` enum; `hold(...)` gains `transition:` |
| `BellasReefKit/Sources/BellasReefKit/LightingCards.swift` | `ActiveHold.transition`; `lightingCards` maps it |
| `BellasReefKit/Tests/BellasReefKitTests/OverrideTests.swift` | request body carries `transition`; stubs carry it |
| `BellasReefKit/Tests/BellasReefKitTests/LightingCardsTests.swift` | fixture + assertions carry `transition` |
| `BellasReef/Views/LightingView.swift` | segmented control, `@AppStorage`, hold() passes it, active-hold row shows it |

---

### Task 1: Re-pin contracts to 3.8.0 and make the kit compile again

**Files:**
- Modify (by script): `Contracts/openapi.json`, `Contracts/stream-frames.schema.json`, `BellasReefKit/Sources/BellasReefAPI/openapi.json`
- Modify: `Contracts/PINNED.md`
- Modify: `BellasReefKit/Sources/BellasReefKit/HubClient.swift:415-455`, `BellasReefKit/Sources/BellasReefKit/LightingCards.swift:31-45,89-91`
- Test: `BellasReefKit/Tests/BellasReefKitTests/OverrideTests.swift`, `BellasReefKit/Tests/BellasReefKitTests/LightingCardsTests.swift`

**Interfaces:**
- Produces: `public enum HoldTransition: String, CaseIterable, Sendable, Equatable { case snap, ramp }` in `HubClient.swift`; `HubClient.hold(target: String, duty: Double, durationS: Double, reason: String, transition: HoldTransition) async throws -> HoldOutcome`; `LightingCard.ActiveHold(id:duty:expiresAt:transition:)` with `public let transition: HoldTransition`; `LightingFixtures.override(id:duty:expiresInS:transition:)` (default `.ramp`).

- [ ] **Step 1: Branch and re-pin**

```bash
cd /Users/david/visualstudio/bellasreef-ios
git checkout -b feat/hold-transition main
./scripts/pin-contracts.sh 32085994939
git --no-pager diff --stat
```
Expected: the three JSON files change; `git diff Contracts/openapi.json` shows `info.version` 3.8.0 and `transition` (enum `snap`/`ramp`) on `OverrideRequest` (with `default: ramp`), `OverrideView` (required) and — in `stream-frames.schema.json` — `OverrideContext` (required). If the artifact download fails (auth), stop and report BLOCKED with the `gh` error.

- [ ] **Step 2: Update `Contracts/PINNED.md`**

Table rows: Backend commit `91742b8` · CI run `32085994939` (`client-contracts` artifact) · Pinned on 2026-08-17 · Contracts version 3.8.0 (paths count unchanged — check the file's own "OpenAPI 3.1.0, N paths" line against `jq '.paths | length' Contracts/openapi.json`). Append:

```markdown
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
```

- [ ] **Step 3: Run the kit tests to see the compile failures (RED)**

```bash
cd BellasReefKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -scheme BellasReefKit-Package -destination 'platform=iOS Simulator,id=9438872C-7EF2-4BA7-837F-1C55F938E6DF' -skipPackagePluginValidation 2>&1 | grep -E "error:|Test Suite|passed|failed" | head -30
```
Expected: compile errors in `LightingCardsTests.swift` (`OverrideContext.init` missing `transition`) — that is the contract telling us it changed (PRD G3).

- [ ] **Step 4: Write the failing kit tests**

In `OverrideTests.swift`:
- `holdRequestBody`: change the call to `client.hold(target: "light-1", duty: 0.6, durationS: 1200, reason: "manual", transition: .snap)` and add `#expect(parsed?["transition"] as? String == "snap")`; add `"transition": "snap"` to that stub's JSON reply.
- Every other stub JSON for `createOverride` 200 responses in the file (the `holdGrants` one at ~line 40): add `"transition": "ramp"`; update every `client.hold(...)` call in the file to pass `transition: .ramp`.
- `holdGrants`: extend the assertion so the granted view's `transition` is `.ramp` (`overrideView.transition == .ramp` — the generated enum; the exact Swift type is `Components.Schemas.OverrideView.TransitionPayload`, check the generated name with `grep -n "TransitionPayload" BellasReefKit/.build/**/Types.swift` or by compiling once).
- New test:

```swift
    @Test("HoldTransition maps 1:1 onto the wire values")
    func transitionWire() {
        #expect(HoldTransition.snap.rawValue == "snap")
        #expect(HoldTransition.ramp.rawValue == "ramp")
        #expect(HoldTransition.allCases == [.snap, .ramp])
    }
```

In `LightingCardsTests.swift`:
- `LightingFixtures.override(...)` gains `transition: Components.Schemas.OverrideContext.TransitionPayload = .ramp` and passes `transition: transition` to `.init(...)`.
- `frameWithOverrideShowsHold`: build the override with `transition: .snap` and assert `cards[0].hold == LightingCard.ActiveHold(id: ..., duty: 0.6, expiresAt: ..., transition: .snap)`.
- New test:

```swift
    @Test("the hold's transition comes off the frame, ramp and snap alike")
    func holdTransitionOffTheFrame() {
        let device = LightingFixtures.device(id: "light-1")
        for (wire, expected) in [
            (Components.Schemas.OverrideContext.TransitionPayload.ramp, HoldTransition.ramp),
            (.snap, .snap),
        ] {
            let frame = LightingFixtures.frame(
                id: "light-1", override: LightingFixtures.override(transition: wire))
            let cards = lightingCards(devices: [device], frames: ["light-1": frame])
            #expect(cards[0].hold?.transition == expected)
        }
    }
```
- Any other `LightingCard.ActiveHold(...)` construction in the tests (`effectiveHold` tests) gains `transition: .ramp`.

- [ ] **Step 5: Run to confirm RED for the new assertions**

Same command as Step 3. Expected: compile errors now name `HoldTransition` (undefined) and `ActiveHold.init` (extra argument).

- [ ] **Step 6: Implement**

`HubClient.swift`, just above `HoldOutcome`:

```swift
    /// How the hub moves a light to a held level and back — the operator's
    /// choice per hold (backend spec 2026-08-17). `snap` is one step on
    /// arrival AND on release/expiry; `ramp` is the hub's global slew both
    /// ways. Hand-written wrapper over the generated
    /// `OverrideRequest.TransitionPayload` so the view never touches a
    /// generated enum name — the mapping below is the only place they meet.
    public enum HoldTransition: String, CaseIterable, Sendable, Equatable {
        case snap
        case ramp

        var payload: Components.Schemas.OverrideRequest.TransitionPayload {
            switch self {
            case .snap: .snap
            case .ramp: .ramp
            }
        }

        init(_ payload: Components.Schemas.OverrideContext.TransitionPayload) {
            switch payload {
            case .snap: self = .snap
            case .ramp: self = .ramp
            }
        }

        init(_ payload: Components.Schemas.OverrideView.TransitionPayload) {
            switch payload {
            case .snap: self = .snap
            case .ramp: self = .ramp
            }
        }
    }
```
(If the generator emits ONE shared enum type for the three schemas rather than three payload types, keep a single `init` and mapping — check the generated `Types.swift`; the switch stays exhaustive so a third wire value is a compile error.)

`hold(...)`:

```swift
    public func hold(
        target: String, duty: Double, durationS: Double, reason: String,
        transition: HoldTransition
    ) async throws -> HoldOutcome {
        switch try await client.createOverride(
            body: .json(.init(
                durationS: durationS, duty: duty, reason: reason, target: target,
                transition: transition.payload
            ))
        ) {
```
(argument order follows the generated memberwise init — alphabetical; let the compiler tell you.)

`LightingCards.swift` — `ActiveHold`:

```swift
        public let id: String
        public let duty: Double
        public let expiresAt: Date
        /// How this hold arrives and how it will leave — snap or ramp
        /// (backend spec 2026-08-17). Off `OverrideContext.transition`,
        /// required on the wire, so always present whenever `hold` is.
        public let transition: HoldTransition

        public init(id: String, duty: Double, expiresAt: Date, transition: HoldTransition) {
            self.id = id
            self.duty = duty
            self.expiresAt = expiresAt
            self.transition = transition
        }
```
and in `lightingCards`: `LightingCard.ActiveHold(id: $0.id, duty: $0.duty, expiresAt: $0.expiresAt, transition: HoldTransition($0.transition))`.

- [ ] **Step 7: Kit tests GREEN**

Same command as Step 3. Expected: all kit tests pass, no new warnings. `diff -q Contracts/openapi.json BellasReefKit/Sources/BellasReefAPI/openapi.json` prints nothing.

- [ ] **Step 8: Commit**

```bash
git add Contracts BellasReefKit
git commit -m "feat(kit): contracts 3.8.0 — holds carry transition snap|ramp

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Lighting tab — Snap | Ramp control, persisted choice, shown on the active hold

**Files:**
- Modify: `BellasReef/Views/LightingView.swift` (card view: state ~L140-190, active-hold row ~L252-275, controls ~L290-300, `hold()` ~L468-500)

**Interfaces:**
- Consumes: `HoldTransition`, `HubClient.hold(..., transition:)`, `LightingCard.ActiveHold.transition` (Task 1).

- [ ] **Step 1: Add the persisted choice**

In the card view's state block (next to `@State private var proposedDuty`):

```swift
    /// The operator's snap-vs-ramp choice, remembered across cards and
    /// launches (`@AppStorage`, spec 2026-08-17). First-run default is
    /// snap — the complaint that started this was a hold taking ~100 s to
    /// arrive. Stored as the wire string so a stale value can never decode
    /// to something the hub would reject; anything unreadable falls back to
    /// snap.
    @AppStorage("lighting.holdTransition") private var transitionRaw: String = HoldTransition.snap.rawValue

    private var transition: HoldTransition {
        get { HoldTransition(rawValue: transitionRaw) ?? .snap }
        nonmutating set { transitionRaw = newValue.rawValue }
    }
```

- [ ] **Step 2: The control, beside Hold**

Replace the bare `Button { Task { await hold() } } label: {...}` region with an `HStack` holding a segmented picker and the Hold button:

```swift
            HStack(spacing: 12) {
                Picker("Transition", selection: Binding(
                    get: { transition }, set: { transition = $0 }
                )) {
                    Text("Snap").tag(HoldTransition.snap)
                    Text("Ramp").tag(HoldTransition.ramp)
                }
                .pickerStyle(.segmented)
                .disabled(submitting)
                .frame(maxWidth: 160)
                .accessibilityIdentifier("lighting-transition-\(card.id)")
                .accessibilityLabel("Transition")

                Button {
                    Task { await hold() }
                } label: {
                    if submitting { ProgressView() } else { Text("Hold") }
                }
                // (keep every existing modifier on the Hold button exactly as it is)
            }
```
Keep the existing Hold button's modifiers (`.buttonStyle`, `.disabled(...)`, `.accessibilityIdentifier("lighting-hold-\(card.id)")` etc.) — move them, do not drop any. Under the row, one quiet caption in the file's existing footnote idiom (`Theme.caption`, `Theme.secondaryText`): `Text("Snap goes to the level at once and leaves it at once. Ramp fades at the hub's rate, both ways.")`.

- [ ] **Step 3: Send it, and show it**

`hold()`: `client.hold(target: card.id, duty: proposedDuty / 100, durationS: durationS, reason: "manual", transition: transition)`; the optimistic hold: `LightingCard.ActiveHold(id: overrideView.id, duty: overrideView.duty, expiresAt: overrideView.expiresAt, transition: HoldTransition(overrideView.transition))`.

Active-hold row label: `"Held at \(Int(hold.duty * 100))% · \(Self.label(for: hold.transition)) · \(formatRemaining(...))"` with

```swift
    private static func label(for transition: HoldTransition) -> String {
        switch transition {
        case .snap: "Snap"
        case .ramp: "Ramp"
        }
    }
```
and `truthAccessibilityLabel` appends `"held at N percent, snap"` / `", ramp"` accordingly (`parts.append("held at \(Int(hold.duty * 100)) percent, \(Self.label(for: hold.transition).lowercased())")`).

- [ ] **Step 4: Build the app**

```bash
cd /Users/david/visualstudio/bellasreef-ios && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project BellasReef.xcodeproj -scheme BellasReef -destination 'platform=iOS Simulator,id=9438872C-7EF2-4BA7-837F-1C55F938E6DF' -skipPackagePluginValidation 2>&1 | grep -E "error:|warning:|BUILD" | head -20
```
Expected: `BUILD SUCCEEDED`, no new warnings.

- [ ] **Step 5: Install on the sim and screenshot the Lighting tab (evidence, not a gate)**

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/BellasReef.app" -newer project.yml | head -1)
xcrun simctl boot 9438872C-7EF2-4BA7-837F-1C55F938E6DF 2>/dev/null; xcrun simctl install 9438872C-7EF2-4BA7-837F-1C55F938E6DF "$APP" && xcrun simctl launch 9438872C-7EF2-4BA7-837F-1C55F938E6DF $(defaults read "$APP/Info.plist" CFBundleIdentifier)
```
Then `xcrun simctl io 9438872C-7EF2-4BA7-837F-1C55F938E6DF screenshot /private/tmp/claude-501/-Users-david-visualstudio-bellasreef/bd1c74dc-8a60-4614-bf1a-3ba98710a0e6/scratchpad/lighting-transition.png` after navigating to the Lighting tab (the sim is a paired client "iPhone 9EAC" against the live hub; do not place a hold — David drives the bench). If the sim cannot be driven, report the build success and skip the screenshot — say so.

- [ ] **Step 6: Commit**

```bash
git add BellasReef
git commit -m "feat(lighting): Snap | Ramp beside Hold — persisted per operator, shown on the active hold

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: PR, CI, install for the bench

- [ ] Push (David may need `--no-verify` if a hook trips) and `gh pr create` with body: spec pointer, "contracts re-pinned to 3.8.0 (backend #42, run 32085994939)", the three kit changes, the view change, and the bench card: snap Hold 0 → 100 % on Light 0 must reach 3.308 V within ~1 s and Release 0 V within ~1 s; Ramp Hold still ~100 s; snap 5 % → 0 V; same on Light 1.
- [ ] `gh pr checks --watch`; merge `--squash --delete-branch`; install the merged build on the iPhone 17 sim (Task 2 Step 5 commands) so David's next bench run is on `main`.

---

## Self-review

- **Spec coverage:** regenerate from 3.8.0 (T1); segmented Snap | Ramp beside Hold, `@AppStorage`, default snap (T2); active-hold row shows transition (T2); nothing else moves (T2 keeps every existing control/modifier); bench proof (T3).
- **Placeholders:** none; the one open detail (generated enum type names) is resolved by the compiler with an explicit instruction.
- **Type consistency:** `HoldTransition` raw `String`; `hold(..., transition: HoldTransition)`; `ActiveHold.transition`; fixture default `.ramp`; view key `lighting.holdTransition`.
