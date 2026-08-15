# UX Fixes and Setup-Code Onboarding — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the three client defects from the 2026-08-15 walkthrough
(History rendering its own cancellation as a fatal raw-error dump; unadopted
devices lingering as adopted; audit rows that say nothing) and add the
setup-code onboarding from the approved new-owner spec — against contracts
3.7.0.

**Architecture:** All state logic stays in BellasReefKit (testable,
`@Observable` models); views stay declarative. The generated client is
regenerated from the backend's committed 3.7.0 spec — never hand-written
bindings. Error presentation converges on one Kit helper so "two
error-formatting idioms app-wide" (PR #2 ledger) closes rather than growing a
third.

**Tech Stack:** Swift/SwiftUI, iOS 26+, swift-openapi-generator, XCTest
(kit: `swift test`; app: xcodebuild on the iPhone 17 sim, UDID
9438872C-7EF2-4BA7-837F-1C55F938E6DF).

**Spec:** backend repo `docs/superpowers/specs/2026-08-15-new-owner-experience-design.md`
(Feature 2 is this repo's; features 1/3 are the backend plan's). The three
fixes argue from the 2026-08-15 triage findings recorded in each task.

**Prerequisite:** the backend plan
(`../bellasreef/docs/superpowers/plans/2026-08-15-live-adoption-audit-and-new-owner.md`)
is merged through its Task 7 (contracts 3.7.0 committed) — Task 1 here re-pins
against that artifact. Tasks 2 can start before that; 1 and 3–5 cannot.

## Global Constraints

- Design-brief laws: §7.1 states everywhere (idle/loading/loaded/empty/failed); error text is amber (`Theme.attention`), never red; red is reserved for destructive actions.
- No hand-written API bindings — regenerate, then compile; drift is a compile error (PRD G3).
- Kit logic gets kit tests; UI states get their §7.1 coverage; the full pairing path is bench-verified, not CI-run.
- `DEVELOPER_DIR=/Applications/Xcode.app` for all xcrun/xcodebuild invocations. `command ls` (not bare `ls`, which is eza-aliased) when scripting.
- Conventional commits; PR against main; CI green before merge.

---

### Task 1: re-pin contracts at 3.7.0 and regenerate the client

**Files:**
- Modify: the vendored OpenAPI document (wherever the repo pins it — locate with `git log --oneline --follow -- '**/openapi.*'`; the 3.5.0 re-pin of 2026-08-12 is the precedent commit to imitate)
- Regenerate: `BellasReefAPI` generated sources (build-time plugin or committed output — follow the repo's existing mechanism)

**Interfaces:**
- Consumes: backend repo's committed 3.7.0 `openapi.json` (backend Task 7).
- Produces: generated Swift for `Info.setupMode`, `PairRequest.setup_code`, `AuditEvent.action`, `DeviceView.adopted`, `readoptDevice(...)`, `forgetDevice(...)` — the symbols Tasks 3–5 compile against.

- [ ] **Step 1:** Copy the backend's regenerated spec over the vendored copy, byte-identical (the 2026-08-12 session log: both copies byte-identical is the invariant).
- [ ] **Step 2:** Regenerate/build so the new operations exist. Run: `cd BellasReefKit && swift build`. Expected: compiles; new symbols resolve (spot-check: `grep -r "setupMode" .build` or open the generated types).
- [ ] **Step 3:** Run the kit suite. Run: `cd BellasReefKit && swift test`. Expected: all green (additive change; nothing breaks).
- [ ] **Step 4:** Commit.

```bash
git add -A
git commit -m "chore(contracts): re-pin at 3.7.0

Picks up setup_mode/setup_code (new-owner spec), AuditEvent.action,
DeviceView.adopted, readoptDevice, forgetDevice."
```

---

### Task 2: History — cancellation is not an error, loads are single-flight, errors are sentences

Triage finding, confirmed 2026-08-15: `HistoryModel.load()` catches
`CancellationError`/URLError −999 (its own `.task` being cancelled by a tab
switch, or a racing `range.didSet` load) and stamps
`state = .failed("\(error)")` — a permanent failure screen carrying a raw
transport dump, for a request the app itself cancelled. Server-side was
verified healthy (API→VM queries 200).

**Files:**
- Create: `BellasReefKit/Sources/BellasReefKit/HumanError.swift`
- Modify: `BellasReefKit/Sources/BellasReefKit/HistoryModel.swift` (load/range, ~lines 120–161)
- Modify: `BellasReef/Views/HistoryView.swift` (`.task` block, ~line 34)
- Modify: `BellasReef/Views/SystemView.swift` (`"\(error)"` sites at ~466, ~456 adopt the helper — closes the ledgered two-idioms item)
- Test: `BellasReefKit/Tests/BellasReefKitTests/HumanErrorTests.swift` (create), `HistoryModelTests` (extend where the suite already fakes the client)

**Interfaces:**
- Consumes: existing `HistoryModel` state machine (`.loading/.loaded/.empty/.failed(String)`), its `client.history(...)` call; whatever fake `HubClient`/transport the kit tests already use for HistoryModel.
- Produces:
  - `HumanError.isCancellation(_ error: any Error) -> Bool` — true for `CancellationError`, `URLError.cancelled`, NSURLErrorDomain −999, walking wrapped/underlying errors (swift-openapi ClientError wraps the transport error).
  - `HumanError.describe(_ error: any Error) -> String` — one short sentence: connection-shaped failures → "The hub did not answer. Check that this device is on the tank's network."; HTTP-shaped → "The hub answered with an error (code N)."; anything else → "Something went wrong talking to the hub." Full raw error goes to the log at the call site, never to the screen.
  - `HistoryModel.reload()` — cancel-and-replace single-flight entry point.

- [ ] **Step 1: Write the failing kit tests**

```swift
// HumanErrorTests.swift
import XCTest
@testable import BellasReefKit

final class HumanErrorTests: XCTestCase {
    func testSwiftCancellationIsCancellation() {
        XCTAssertTrue(HumanError.isCancellation(CancellationError()))
    }

    func testURLErrorCancelledIsCancellation() {
        XCTAssertTrue(HumanError.isCancellation(URLError(.cancelled)))
    }

    func testWrappedMinus999IsCancellation() {
        let ns = NSError(domain: NSURLErrorDomain, code: -999)
        let wrapped = NSError(domain: "whatever", code: 1,
                              userInfo: [NSUnderlyingErrorKey: ns])
        XCTAssertTrue(HumanError.isCancellation(wrapped))
    }

    func testTimeoutIsNotCancellation() {
        XCTAssertFalse(HumanError.isCancellation(URLError(.timedOut)))
    }

    func testDescriptionIsOneSentenceNotADump() {
        let text = HumanError.describe(URLError(.timedOut))
        XCTAssertFalse(text.contains("NSURLErrorDomain"))
        XCTAssertLessThan(text.count, 120)
    }
}
```

And on `HistoryModel`, following the suite's existing fake-client pattern:

```swift
func testCancelledLoadLeavesStateAlone() async {
    // fake client whose history(...) throws URLError(.cancelled)
    let model = makeModel(throwing: URLError(.cancelled))
    await model.load()
    // still .loading (never completed), NOT .failed
    XCTAssertNotEqual(model.state, .failed(describing: "cancelled"))
    if case .failed = model.state { XCTFail("cancellation rendered as failure") }
}

func testRealFailureIsHumanReadable() async {
    let model = makeModel(throwing: URLError(.timedOut))
    await model.load()
    guard case let .failed(why) = model.state else { return XCTFail() }
    XCTAssertFalse(why.contains("operationID"))
    XCTAssertFalse(why.contains("NSURLErrorDomain"))
}
```

(Adapt `makeModel(throwing:)` to the fixtures the file already has; if
HistoryModel has no fake-client test yet, add the minimal fake conforming to
whatever protocol `client` is — check how `EquipmentRows`/PR #2 tests fake it.)

- [ ] **Step 2:** Run: `cd BellasReefKit && swift test --filter HumanError`. Expected: FAIL (type doesn't exist).

- [ ] **Step 3: Implement HumanError**

```swift
import Foundation

/// The one error-presentation idiom (PR #2 ledger: there were two; now
/// there is this). Raw errors go to the log; people get a sentence.
public enum HumanError {
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        var next: (any Error)? = error
        while let current = next {
            let ns = current as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return true
            }
            next = ns.userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return false
    }

    public static func describe(_ error: any Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .timedOut:
                return "The hub did not answer. Check that this device is on the tank's network."
            default:
                break
            }
        }
        return "Something went wrong talking to the hub."
    }
}
```

Then extend `describe` for the generated client's error shape: read how the
repo currently stringifies OpenAPI runtime errors (the SystemView sites) and
add a case that extracts an HTTP status if one is present ("The hub answered
with an error (code N)."). Also make `isCancellation` unwrap the OpenAPI
`ClientError`'s `underlyingError` property explicitly if the NSError bridge
does not surface it — write the wrapped-ClientError test first to find out.

- [ ] **Step 4: Fix HistoryModel**

```swift
@ObservationIgnored private var loadTask: Task<Void, Never>?

public var range: HistoryRange = .day {
    didSet { reload() }
}

/// Single-flight: a new reload cancels the one in flight, so only the
/// latest request ever writes state (the 09:04:54 race, 2026-08-15).
public func reload() {
    loadTask?.cancel()
    loadTask = Task { await load() }
}

public func load() async {
    if traces.isEmpty { state = .loading }
    let end = Date()
    let start = end.addingTimeInterval(-range.duration)
    window = start...end
    do {
        let view = try await client.history(from: start, to: end, buckets: range.buckets)
        try Task.checkCancellation()   // a cancelled load must not publish results
        // ... existing trace/episode/state assembly unchanged ...
    } catch {
        // Our own cancellation is not news: leave state exactly as it was;
        // the next .task or reload gets a clean run. (Finding 2026-08-15:
        // this rendered as a permanent raw-dump failure screen.)
        guard !HumanError.isCancellation(error) else { return }
        log.error("history load failed: \(String(describing: error))")
        state = .failed(HumanError.describe(error))
    }
}
```

- [ ] **Step 5: Fix the view's self-healing**

`HistoryView.swift` `.task` (line 34): loading now happens on every
appearance, not only on creation — a cancelled prefetch heals on the next
visit:

```swift
.task {
    if history == nil, let client = model.client, let catalog = model.catalog {
        history = HistoryModel(client: client, catalog: catalog)
    }
    await history?.load()
}
```

Leave `.refreshable`/retry-button/`scenePhase` paths calling `load()` — with
single-flight in `reload()` and cancellation-transparency in `load()`, both
entry points are now safe.

- [ ] **Step 6: Converge SystemView's raw idioms**

Replace `unadoptProblem = "\(error)"` (SystemView.swift:466) and
`revokeProblem = "\(error)"` (:456) with `HumanError.describe(error)`, logging
the raw error beside each.

- [ ] **Step 7:** Run: `cd BellasReefKit && swift test` and build the app
(`xcodebuild -scheme BellasReef -destination 'platform=iOS Simulator,id=9438872C-7EF2-4BA7-837F-1C55F938E6DF' build`).
Expected: green, warning-free.

- [ ] **Step 8: Commit**

```bash
git add BellasReefKit BellasReef
git commit -m "fix(history): cancellation is not an error, loads are single-flight

The tab rendered its own cancelled prefetch as a permanent failure
carrying the raw transport dump. Cancellation now leaves state alone,
range changes cancel the in-flight load, real failures read as one
amber sentence via HumanError - the app's single error idiom."
```

---

### Task 3: System — Detached section with Re-add and Clear

Triage finding: after unadopt the device stayed listed as adopted (second
DELETE hit 404 on the hub). Backend keeps detached rows by design and now
says so (`DeviceView.adopted`), with `readoptDevice`/`forgetDevice` to act on
them (backend Task 3). Ruled 2026-08-15: show them in a Detached section with
re-add and clear.

**Files:**
- Modify: `BellasReef/Views/SystemView.swift` (hardware section, ~lines 280–345; actions ~435–469)
- Modify: `BellasReefKit` `HubClient` wrapper if operations are wrapped there (follow how `unbind(deviceId:)` is exposed and add `readopt`/`forget` beside it)
- Test: app UI/unit tests where PR #2 put `equipmentRows`-style logic (any new pure sectioning logic goes in Kit with a test)

**Interfaces:**
- Consumes: `DeviceView.adopted`, `readoptDevice`, `forgetDevice` from Task 1's regenerated client.
- Produces: `hardwareSectioned: (adopted: [DeviceView], detached: [DeviceView])` — pure, kit-tested if extracted; UI: adopted rows unchanged; detached rows show name + "released — history kept" subtitle, a `Re-add` (plain) and `Clear` (destructive, confirmed) action.

- [ ] **Step 1: Write the failing test** for the pure split (put it beside the
`equipmentRows` tests, same style):

```swift
func testHardwareSectionsSplitOnAdopted() {
    let rows = [device(id: "a", adopted: true), device(id: "b", adopted: false)]
    let split = hardwareSections(rows)
    XCTAssertEqual(split.adopted.map(\.deviceId), ["a"])
    XCTAssertEqual(split.detached.map(\.deviceId), ["b"])
}
```

- [ ] **Step 2:** Run kit tests, expect FAIL; implement the two-line pure
function in Kit; run again, expect PASS.

- [ ] **Step 3: UI**

In the hardware section body: `ForEach` over `split.adopted` for the existing
`adoptedRow`s; below Available channels, when `split.detached` is non-empty:

```swift
Text("Detached")
    .font(Theme.caption)
    .foregroundStyle(Theme.tertiaryText)
ForEach(split.detached, id: \.deviceId) { device in
    detachedRow(device)
}
```

```swift
@ViewBuilder
private func detachedRow(_ device: Components.Schemas.DeviceView) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.displayName ?? device.deviceId)
                .foregroundStyle(Theme.primaryText)
            Text("released — history kept")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        Spacer()
        Button("Re-add") { Task { await readopt(device) } }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("readopt-\(device.deviceId)")
        Button("Clear", role: .destructive) { forgetting = device }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("forget-\(device.deviceId)")
    }
    .frame(minHeight: 44)
}
```

Confirmation dialog for Clear (mirror the existing unadopt dialog's
mechanics, `@State private var forgetting: Components.Schemas.DeviceView?`):

> **Clear this device?**
> Its name and settings are deleted for good. Readings it already recorded
> stay in history. If the hardware comes back, adopting its channel starts
> a fresh device.
> [Clear <name>] (destructive)

Actions, mirroring `unadopt(_:)` (:461) including `await loadHardware()` after
and `HumanError.describe` (Task 2) on failure:

```swift
private func readopt(_ device: Components.Schemas.DeviceView) async {
    unadoptProblem = nil
    do { _ = try await model.client?.readopt(deviceId: device.deviceId) }
    catch { unadoptProblem = HumanError.describe(error) }
    await loadHardware()
}

private func forget(_ device: Components.Schemas.DeviceView) async {
    unadoptProblem = nil
    do { _ = try await model.client?.forget(deviceId: device.deviceId) }
    catch { unadoptProblem = HumanError.describe(error) }
    await loadHardware()
}
```

Also gate the existing `adoptedRow` ForEach on the split so an adopted-only
list is byte-identical to today's rendering.

- [ ] **Step 4:** Build + run app tests on the sim; manually verify against
the live hub: unadopt a light → it moves to Detached with the channel
reappearing under Available; Re-add → returns to adopted with its old name
(and, per backend Task 1, hardware-io restarts within ~15 s — watch
`docker logs` if at the hub); Clear on a detached row → gone, audit shows
`device.forgotten`.

- [ ] **Step 5: Commit**

```bash
git add BellasReef BellasReefKit
git commit -m "feat(system): Detached section - released devices get re-add and clear

Unadopted rows no longer masquerade as adopted (the stale-row 404 from
the 2026-08-15 walkthrough); they move to a Detached section offering
readopt (identity and history reattach) or forget (confirmed, final)."
```

---

### Task 4: Audit log rows say what happened

Triage finding: every row rendered `actor · subject` where subject is always
`bellasreef.audit.auth` — three identical tokens per row, the unadopt
invisible among them. Backend now sends real categories and a typed `action`.

**Files:**
- Modify: `BellasReef/Views/AuditLogView.swift` (row at ~line 89)
- Create: `BellasReefKit/Sources/BellasReefKit/AuditPhrase.swift`
- Test: `BellasReefKit/Tests/BellasReefKitTests/AuditPhraseTests.swift` (create)

**Interfaces:**
- Consumes: `AuditEvent.action: String?` (Task 1), `model.catalog?.name(for:)` (existing device-name lookup the row already uses).
- Produces: `AuditPhrase.title(action: String?, deviceName: String?) -> String` — pure, kit-tested.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import BellasReefKit

final class AuditPhraseTests: XCTestCase {
    func testKnownActionsReadAsVerbs() {
        XCTAssertEqual(AuditPhrase.title(action: "device.unbound", deviceName: "Pretty Blue"),
                       "Unadopted Pretty Blue")
        XCTAssertEqual(AuditPhrase.title(action: "device.bound", deviceName: "Pretty Blue"),
                       "Adopted Pretty Blue")
        XCTAssertEqual(AuditPhrase.title(action: "client.paired", deviceName: nil),
                       "Paired a device")
        XCTAssertEqual(AuditPhrase.title(action: "client.revoked", deviceName: nil),
                       "Revoked a device's access")
        XCTAssertEqual(AuditPhrase.title(action: "token.minted", deviceName: nil),
                       "Signed in")
    }

    func testUnknownActionFallsBackToItself() {
        XCTAssertEqual(AuditPhrase.title(action: "future.event", deviceName: nil),
                       "future.event")
    }

    func testMissingActionSaysRecorded() {
        XCTAssertEqual(AuditPhrase.title(action: nil, deviceName: nil),
                       "Event recorded")
    }
}
```

- [ ] **Step 2:** Run: `cd BellasReefKit && swift test --filter AuditPhrase`. FAIL, then implement:

```swift
/// Verbs for the audit log. Unknown actions fall back to the raw name -
/// a new backend event must never render as a blank row.
public enum AuditPhrase {
    public static func title(action: String?, deviceName: String?) -> String {
        guard let action else { return "Event recorded" }
        let name = deviceName
        switch action {
        case "device.bound":      return "Adopted \(name ?? "a device")"
        case "device.unbound":    return "Unadopted \(name ?? "a device")"
        case "device.forgotten":  return "Cleared \(name ?? "a device")"
        case "device.renamed":    return "Renamed \(name ?? "a device")"
        case "thresholds.set":    return "Set alerts for \(name ?? "a device")"
        case "client.paired":     return "Paired a device"
        case "client.revoked":    return "Revoked a device's access"
        case "pair.collected":    return "Pairing request collected"
        case "pair.denied":       return "Denied a pairing request"
        case "pair.no_approver":  return "Pairing attempted with nobody to approve"
        case "pair.code_rejected": return "Wrong setup code entered"
        case "token.minted":      return "Signed in"
        case "token.rejected":    return "Rejected a sign-in"
        case "override.created":  return "Manual override started"
        case "override.released": return "Manual override ended"
        default:                  return action
        }
    }
}
```

Run again: PASS. (Cross-check the action strings against the backend's sink
call sites — the backend plan's Task 2 lists them; any string mismatch is a
bug on whichever side diverged from the other.)

- [ ] **Step 3: Re-shape the row** (AuditLogView.swift:89):

```swift
private func row(_ event: Components.Schemas.AuditEvent) -> some View {
    // chip: event.category (unchanged)
    // title:
    Text(AuditPhrase.title(
        action: event.action,
        deviceName: event.deviceId.map { model.catalog?.name(for: $0) ?? $0 }))
        .foregroundStyle(Theme.primaryText)
    // detail line: actor + relative time; the subject string is gone
    Text("\(event.actor) · \(RelativeAge.describe(from: event.occurredAt))")
        .font(Theme.caption)
        .foregroundStyle(Theme.tertiaryText)
}
```

Keep the existing layout scaffolding (HStack/VStack, chip placement) — only
the text content changes. The device-name line the row already had merges
into the title; delete the now-redundant separate device line.

- [ ] **Step 4:** Build, run kit + app tests, then verify live: perform one
rename on the hub and confirm the new row reads "Renamed <name>" with a
`config` chip while old rows (pre-migration events) still render via the
fallbacks.

- [ ] **Step 5: Commit**

```bash
git add BellasReef BellasReefKit
git commit -m "feat(audit): rows read as verbs, not subjects

'auth - api - bellasreef.audit.auth' three times per screen becomes
'Unadopted Pretty Blue - api - 2m ago'. Unknown actions fall back to
their raw name so future backend events stay legible."
```

---

### Task 5: setup-code onboarding (spec Feature 2)

**Files:**
- Modify: `BellasReef/Views/PairingFlow.swift` (branch after hub identify, ~`action(_ info:)` at line 223)
- Create: `BellasReef/Views/SetupCodeEntry.swift`
- Create: `BellasReefKit/Sources/BellasReefKit/SetupCode.swift` (normalization mirror)
- Test: `BellasReefKit/Tests/BellasReefKitTests/SetupCodeTests.swift`

**Interfaces:**
- Consumes: `Info.setupMode`, `pair(client_name:setup_code:)` from the 3.7.0 client; the flow's existing `pair()` / `complete(refreshToken:clientId:using:)` plumbing (PairingFlow.swift:334, 361).
- Produces: `SetupCode.normalize(_ entry: String) -> String` (uppercase, strip dashes/spaces — the backend's normalization, mirrored per spec); `SetupCode.display(_ entry: String) -> String` (4-4 grouping as you type); `SetupCodeEntry` view with §7.1 states: idle, submitting, rejected(reason), throttled.

- [ ] **Step 1: Write the failing kit tests**

```swift
final class SetupCodeTests: XCTestCase {
    func testNormalizeMirrorsTheBackend() {
        XCTAssertEqual(SetupCode.normalize("7kf2-9qmd"), "7KF29QMD")
        XCTAssertEqual(SetupCode.normalize(" 7KF2 9QMD "), "7KF29QMD")
    }

    func testDisplayGroupsFourFour() {
        XCTAssertEqual(SetupCode.display("7KF29QMD"), "7KF2-9QMD")
        XCTAssertEqual(SetupCode.display("7KF"), "7KF")   // no dash until it earns one
    }
}
```

- [ ] **Step 2:** Run (`swift test --filter SetupCode`), FAIL, implement:

```swift
public enum SetupCode {
    public static func normalize(_ entry: String) -> String {
        entry.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func display(_ entry: String) -> String {
        let raw = normalize(entry)
        guard raw.count > 4 else { return raw }
        return "\(raw.prefix(4))-\(raw.dropFirst(4).prefix(4))"
    }
}
```

Run again: PASS.

- [ ] **Step 3: The entry screen**

`SetupCodeEntry.swift` — follow the visual language of `HubIdentifyCard`
(same card styling, Theme fonts/colors):

- Copy, from the spec verbatim: title "Enter the setup code", body "Enter the
  setup code from your deploy terminal."
- A single TextField bound through `SetupCode.display` (monospaced,
  `.textInputAutocapitalization(.characters)`, `.autocorrectionDisabled()`),
  submit enabled at 8 normalized characters.
- States (§7.1): idle; submitting (button shows ProgressView, field
  disabled); rejected — the server's 422 reason in `Theme.attention`, field
  kept for retry; throttled — 429 renders "Too many attempts — wait a
  minute." in `Theme.attention`.
- Submit calls the flow's pair path with
  `setup_code: SetupCode.normalize(entry)`; a granted response feeds the
  existing `complete(refreshToken:clientId:using:)` — the same landing the
  window flow uses.

- [ ] **Step 4: Branch the flow**

In `PairingFlow`'s post-identify action UI (the `action(_ info:)` builder,
:223): when `info.setupMode == true`, present `SetupCodeEntry` instead of the
request-and-wait UI. When `false`, today's flow is untouched (spec: "the
request-and-wait flow is unchanged").

- [ ] **Step 5:** Build + tests. Full first-pair verification is the
bench-acceptance step (below), not CI.

- [ ] **Step 6: Commit**

```bash
git add BellasReef BellasReefKit
git commit -m "feat(pairing): setup-code entry for a hub that has never paired

When /info says setup_mode, the flow asks for the printed code (4-4
grouped, case- and dash-insensitive) and lands directly in the paired
state; rejection and throttle render per the design brief."
```

---

### Task 6: PR, CI, and the bench acceptance walkthrough

**Files:** none (procedural gate)

- [ ] **Step 1:** Push branch, open PR (link this plan + the spec), CI green, David reviews, merge.
- [ ] **Step 2:** Install the merged build on the iPhone 17 sim.
- [ ] **Step 3:** Pre-wipe verification against the live hub: History loads (and recovers after rapid tab-switching); unadopt → Detached → Re-add round-trip; Clear removes; audit rows read as verbs.
- [ ] **Step 4:** Hand back to the backend plan's factory-reset step. The order of the day's end, per David: he unpairs the sim → `scripts/factory-reset-pi.sh` runs (mandatory backup, typed confirmation) → deploy prints the setup code → fresh app install → **enter code → paired → adopt devices → telemetry on the wire**. That last chain is the spec's acceptance test, run by David with the code from his terminal.

---

## Self-Review Notes

- Spec Feature 2 coverage: re-pin (Task 1), entry screen + states + flow branch (Task 5), normalization mirror kit-tested (Task 5), bench acceptance (Task 6). Findings coverage: History (Task 2), stale row → Detached (Task 3), audit rows (Task 4).
- Type consistency: `HumanError.describe`/`isCancellation` used in Tasks 2–3; `SetupCode.normalize/display` defined and consumed in Task 5; `hardwareSections` named identically in test and UI steps.
- The client method names (`readopt(deviceId:)`, `forget(deviceId:)`) assume the repo wraps generated operations the way `unbind(deviceId:)` is wrapped — Task 3 says to follow that pattern; the generated operationIds are `readoptDevice`/`forgetDevice`.
