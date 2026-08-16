# Lighting Manual Control — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Lighting tab becomes a real control surface: one card per
adopted light with a 0–100% slider, a duration menu, Hold and Release —
honest about the 8% dead band, the deadline, and the hub-reported truth.

**Architecture:** Pure card-state logic in BellasReefKit (registry + stream
frame + active override → card state), views stay declarative. Commands go
through new HubClient wrappers over the ALREADY-GENERATED override operations
(`createOverride`, `releaseOverride`, `listOverrides` — in the 3.7.0 client
since before this pass; no re-pin, no contract change). Override STATE arrives
on the existing stream frames (`frame.override`: duty + expiresInS) — no new
polling.

**Tech Stack:** Swift/SwiftUI, iOS 26+, swift-testing kit tests, xcodebuild on
the iPhone 17 sim (UDID 9438872C-7EF2-4BA7-837F-1C55F938E6DF,
`DEVELOPER_DIR=/Applications/Xcode.app`).

**Spec:** backend repo
`docs/superpowers/specs/2026-08-15-lighting-manual-control-design.md`
(Feature 2). Backend Feature 1 (engine honors unprofiled holds) ships first —
this plan's acceptance depends on it being deployed.

## Global Constraints

- Design-brief laws: §7.1 states; amber errors via `HumanError.describe` (never raw `"\(error)"` — the idiom is law since today's final review); red reserved for destructive (nothing here qualifies — Release is not destructive).
- No hand-written bindings; no vendored-spec change (drift = stop).
- The card renders the HUB's state (frame), never the slider's local value, as the truth line.
- Copy pinned by the spec, verbatim where quoted: footnote "Below 8% this dimmer is off."; clock-503 state "The hub's clock is not trusted yet — holds need a deadline."; empty state "No lights adopted — adopt a PWM channel under System."
- Duration choices: 15 min / 1 h / 4 h / 8 h / Custom; never offer a choice above the target's `max_runtime_s`.
- Kit tests via `xcodebuild test -scheme BellasReefKit-Package -destination 'platform=iOS Simulator,id=9438872C-7EF2-4BA7-837F-1C55F938E6DF'` (plain `swift test` is broken in this sandbox, pre-existing); app build same destination; green + no new warnings before every commit.
- Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer. Branch: feat/lighting-manual-control (create from main).

---

### Task 1: HubClient override wrappers + LightingCardState (kit)

**Files:**
- Modify: `BellasReefKit/Sources/BellasReefKit/HubClient.swift` (three wrappers in the file's established outcome-switch idiom — read `bind`/`unbind`/`readopt` first)
- Create: `BellasReefKit/Sources/BellasReefKit/LightingCards.swift` (pure state mapping)
- Test: `BellasReefKit/Tests/BellasReefKitTests/LightingCardsTests.swift` (create), plus HubClient outcome tests beside the existing pairing/binding ones

**Interfaces:**
- Consumes: generated `Client.createOverride/releaseOverride/listOverrides` (read the vendored openapi.json for their exact request/response shapes — notably what identifies an override for release, and what createOverride returns); `Components.Schemas.DeviceView` (`adopted`, `role`, `actuatorClass`, `maxRuntimeS`); the stream frame's override payload (see TankView.swift:672 usage).
- Produces:
  - `HubClient.hold(target: String, duty: Double, durationS: Double, reason: String) -> HoldOutcome` — outcome enum per the endpoint's documented statuses (200-ish grant, 409 observe-only, 503 clock-untrusted as a DISTINCT case, plus the file's usual auth/unexpected handling). The 503 must be typed, not thrown-generic: the UI renders it as its own state.
  - `HubClient.release(...)` — signature driven by what the generated op needs (override id from the create response or from listOverrides; the implementer reads the schema and picks the minimal honest shape, documented in the report).
  - `lightingCards(devices: [DeviceView], frames: [String: Frame]) -> [LightingCard]` — pure: adopted `light`-role actuators only; each card carries id, name, reported duty (nil if no frame yet), active hold (duty + remaining) if the frame says so, and `maxRuntimeS` for the duration cap. Sorted by name (match how equipmentRows sorts — read it).

- [ ] **Step 1: Failing kit tests** — swift-testing, following EquipmentRowsTests' fixture style: adopted light with frame → card with reported duty; adopted light without frame → card with nil duty ("no state yet" shape); detached light → NO card; sensor → NO card; frame with override → card shows hold (duty + remaining); duration-cap: maxRuntimeS 3600 → choices above 1 h excluded (test the pure cap function, e.g. `allowedDurations(maxRuntimeS:)`).
- [ ] **Step 2:** RED run.
- [ ] **Step 3:** Implement (LightingCards pure; HubClient wrappers exhaustively switching documented statuses; `undocumented` throws, matching the file's idiom).
- [ ] **Step 4:** Kit suite green; app still builds.
- [ ] **Step 5:** Commit: `feat(kit): lighting card state and override command wrappers`.

---

### Task 2: the Lighting tab UI

**Files:**
- Create: `BellasReef/Views/LightingView.swift`
- Modify: `BellasReef/Views/RootView.swift` (~:33 — replace the placeholder `Tab("Lighting", ...)` content with `LightingView`; leave the History/other tabs alone)
- Test: none at app level (no app unit-test target exists — bench acceptance covers it; say so in the report)

**Interfaces:**
- Consumes: Task 1's `lightingCards`, `hold`, `release`, `allowedDurations`; `model.catalog` / the same monitor plumbing TankView uses for frames (read TankView's data flow first and reuse it — do NOT build a second stream consumer); `HumanError.describe`.

- [ ] **Step 1: Build the view.** Structure per the spec: card per light — name; truth line (hub-reported duty as "42%" or the existing "no state yet" voice; if `frame.override` present, the existing "Held at X% · remaining" language plus a Release button); a 0–100% slider (local editing state, clearly the *proposed* value — visually distinct from the truth line); duration menu from `allowedDurations` + Custom (numeric minutes entry, validated ≥1 min and ≤ maxRuntimeS, §7.1 invalid state amber); Hold button posting via `hold(target:duty:durationS:reason:)` with reason `"manual"` (submitting state disables the card's controls; success clears local editing back to tracking; failures render via HumanError EXCEPT the typed clock-503, which renders its pinned copy). Footnote once under the card list: "Below 8% this dimmer is off." Empty state per pinned copy. §7.1 everywhere.
- [ ] **Step 2:** App build green, no new warnings; kit suite still green.
- [ ] **Step 3:** Commit: `feat(lighting): manual hold controls — slider, duration, release`.

---

### Task 3: PR, CI, merge, sim install (procedural)

- [ ] Push branch; PR titled `feat: lighting manual control`; body links the spec and notes acceptance = bench Stage 2 by the operator; CI green; merge (pre-approved on clean review).
- [ ] Build merged main and install on the iPhone 17 sim (default derived data — the generator plugin is only trusted there).
- [ ] Hand back to the controller for hub reset + operator walkthrough.

---

## Self-Review Notes

- Spec Feature 2 covered: layout (T2), truth rules (T2 + pinned copy in constraints), kit logic + wrappers (T1), acceptance deferred to the operator's bench Stage 2 by design.
- Type consistency: `lightingCards`/`allowedDurations`/`hold`/`release` named identically in T1 (producer) and T2 (consumer).
- The one deliberately open shape — how release identifies the override — is delegated to the implementer WITH the instruction to read the generated schema, because the vendored spec is the authority and guessing an id-plumbing shape here would be the plan fabricating a contract detail.
