# Plan — UX findings UX-1..UX-5 (2026-08-14)

Implements the resolutions David approved for the findings in
`docs/reviews/2026-08-14-ux-review.md` (PR #1 branch). Rulings: UX-1 =
implement light mode; UX-2 = build the audit view in iOS (web UI is out of
scope this session); UX-6 deferred to a backend session. Work order is
reverse severity so the UX-1 visual pass sweeps every changed screen once,
at the end.

## Global constraints

- Design brief law (backend repo `docs/ios-design-brief.md`): §2 palette —
  teal is the sole accent and the healthy state; amber = attention; red =
  safety only, never errors; violet = instrumentation silence. §7.1 state
  completeness — every screen distinguishes loading / empty / populated /
  error. §7.5 — WCAG AA (4.5:1) for all text.
- Every colour flows through `Theme` in
  `BellasReefKit/Sources/BellasReefKit/Theme.swift`. No ad-hoc `Color(...)`
  literals in views.
- No hand-written API bindings: REST calls go through the generated
  `BellasReefAPI` client via a `HubClient` wrapper method, matching the
  error-mapping shape of `HubClient.devices()`.
- Swift 6 concurrency-clean; the project builds with zero warnings today.
- Conventional commits, one commit per task, message references the finding
  ID (e.g. `fix(tank): UX-4 sparkline collecting state`).
- The `.xcodeproj` is generated: after editing `project.yml`, run
  `DEVELOPER_DIR=/Applications/Xcode.app xcodegen generate`.
- Build check: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  xcodebuild build -project BellasReef.xcodeproj -scheme BellasReef
  -destination 'platform=iOS Simulator,name=iPhone 17'
  -skipPackagePluginValidation`.
- Kit tests: same but `xcodebuild test -scheme BellasReefKit-Package
  -destination 'platform=iOS Simulator,name=iPhone 17'
  -skipPackagePluginValidation`. Plain `swift test` does NOT work (the
  package is iOS-only; macOS build fails on OpenAPIRuntime minimums).
- Do NOT run the `BellasReefUITests` bench pairing test
  (`-scheme BellasReef` test action) — it spends a hub pairing window.
  Task 1 adds and runs one targeted UI test with `-only-testing`.
- The local simulator is "iPhone 17" (UDID
  9438872C-7EF2-4BA7-837F-1C55F938E6DF), already paired with the hub as
  client "iPhone 9EAC"; the pairing credential lives in the simulator
  keychain and survives app reinstalls.

## Task 1 — UX-5: verify hero tap, fix only if real

The review (finding UX-5) observed that tapping the hero temperature number
does nothing, only the probe-name row opens the sensor detail sheet. But
`BellasReef/Views/TankView.swift:319` already wraps the entire hero block
(name + number + sparkline) in one `Button { onInspect(sensorId) }` with
`.buttonStyle(.plain)`. Either hit-testing fails somewhere inside the
`TimelineView`-wrapped label, or the review's synthetic CGEvent tap missed.

1. Add `BellasReefUITests/HeroTapTests.swift`: launch the app (it comes up
   paired against the live hub), wait for the Tank tab's hero reading to
   exist (a `StaticText` matching the degree symbol, or the button with
   accessibility hint "Opens sensor settings"), then tap **at the hero
   number's own frame** via `element.coordinate(withNormalizedOffset:)` —
   not `element.tap()` on the button, which taps the activation point and
   would mask a partial hit-test hole. Assert the sensor detail sheet
   appears (the "Make primary" or rename control from `SensorDetailSheet`).
   Dismiss the sheet at the end. The test must not pair, adopt, revoke, or
   command anything.
2. Run only this test:
   `xcodebuild test -project BellasReef.xcodeproj -scheme BellasReef
   -destination 'platform=iOS Simulator,name=iPhone 17'
   -skipPackagePluginValidation
   -only-testing:BellasReefUITests/HeroTapTests`.
3. If the tap opens the sheet: the finding is a tooling false negative.
   Keep the test as a regression guard, and amend the UX-5 section of
   `docs/reviews/2026-08-14-ux-review.md` — the review doc lives on branch
   `docs/ux-review-2026-08-14`, so instead record the outcome in the task
   report and in a short note at the top of the test file; the review doc
   amendment happens at PR review time, not in this branch.
4. If the tap genuinely fails: fix hit-testing with
   `.contentShape(Rectangle())` on the Button's label (inside the
   `TimelineView` closure so the shape covers the full laid-out block), rerun
   the test, and keep it green.
5. Commit either way (`test(tank): UX-5 hero tap regression test` or
   `fix(tank): UX-5 whole hero block is one tap target`).

If the app launches unpaired (keychain lost), report BLOCKED — do not open
a pairing window.

## Task 2 — UX-4: sparkline collecting state

`BellasReef/Views/TankView.swift`, `PrimaryReading.reading(now:)`: when a
probe is `.reading` but `monitor.history(sensorId).count <= 1`, the
sparkline block is skipped entirely and the space under the hero is simply
absent. The review (UX-4) wants the blank to be a designed state.

1. In the `.reading` case, add an `else` branch to the existing
   `if monitor.history(sensorId).count > 1`: a single caption line
   `Text("trend: collecting…")` in `Theme.caption` /
   `Theme.tertiaryText`, `.padding(.top, 6)`, marked
   `.accessibilityHidden(true)` (matching the sparkline block it stands in
   for — the trend is decoration to VoiceOver either way). Do NOT reserve
   the 40pt sparkline height; the existing comment explains why an empty
   band reads as a failed load.
2. No new unit tests (pure view composition; the kit has no view tests).
   Verify by building the app target cleanly.
3. Commit: `fix(tank): UX-4 sparkline gains a collecting state`.

## Task 3 — UX-3: Equipment section renders from the device list

`ActuatorSections` in `BellasReef/Views/TankView.swift` renders only from
`monitor.channels` (stream state frames), so "two lights adopted, no frames
yet" is indistinguishable from "nothing adopted" (finding UX-3, brief
§7.1). The registry truth is already on the phone:
`DeviceCatalog.devices` from `GET /devices` (`Components.Schemas.DeviceView`
has `device_id`, `display_name`, `channel`, `role`, `actuator_class`,
`control_authority`).

1. In `BellasReefKit`, add a small pure function (new file
   `EquipmentRows.swift`) that merges the two sources:

   ```swift
   public enum EquipmentRow: Equatable, Identifiable {
       case reporting(id: String, frame: Components.Schemas.StateFrame)
       case adoptedSilent(id: String, name: String)
       public var id: String { … }
   }
   public func equipmentRows(
       devices: [Components.Schemas.DeviceView],
       frames: [String: Components.Schemas.StateFrame],
       roles: [String: String]
   ) -> [(role: String, rows: [EquipmentRow])]
   ```

   Semantics: every adopted actuator device (`actuator_class != nil`)
   appears exactly once — as `.reporting` when a state frame exists for its
   channel id, else `.adoptedSilent`. A frame whose channel id matches no
   adopted device still appears (today's behaviour must not regress),
   grouped under its streamed role. Grouping/ordering keeps the existing
   husbandry order (`light, heater, pump, doser, outlet`, unknowns after,
   `""` = Unassigned). NOTE: whether the frame key is the device's
   `channel` or `device_id` must be verified against `TankMonitor.channels`
   and `DeviceCatalog` — do not guess; read both and match on what the
   code actually keys by.
2. Unit-test the merge in `BellasReefKitTests` (new `EquipmentRowsTests`):
   nothing adopted + no frames → empty; adopted + no frames →
   `.adoptedSilent`; adopted + frame → `.reporting`, no duplicate; frame
   with no adopted device → still present. Construct minimal `DeviceView` /
   `StateFrame` fixtures (see `FrameDecodingTests` for how frames are
   built/decoded).
3. In `ActuatorSections`: accept the catalog (TankView already holds it),
   build sections via `equipmentRows`, render `.adoptedSilent` as a row
   with the device's display name and a `"no state yet"` caption in
   `Theme.tertiaryText` (no duty bar, no percentage — inventing 0% would
   claim a state we do not have). Keep the "No channels reporting yet" copy
   only for the truly-empty case (no adopted actuators AND no frames), and
   reword it to "No equipment adopted yet" when that is what it means —
   i.e. the empty state must now say which emptiness it is.
4. Commit: `fix(tank): UX-3 equipment lists adopted actuators without state`.

## Task 4 — UX-2: audit log view

The brief (§3, tab 4) lists an audit log view; PRD R16 names it; the app
has none (finding UX-2). The generated client already has the operation:
`listAudit` (`GET /api/v1/audit?limit&category` →
`[Components.Schemas.AuditEvent]`; AuditEvent: `message_id`, `occurred_at`
(date-time), `category`, `actor`, `subject`, `device_id` (nullable),
`event` (open object)).

1. `HubClient` gains
   `public func audit(limit: Int? = nil, category: String? = nil) async throws -> [Components.Schemas.AuditEvent]`
   wrapping `listAudit`, with the exact error-mapping shape of `devices()`
   (unauthorized → `credentialWasRejected()`, unprocessable → rejected
   message, undocumented → unexpected).
2. New `BellasReef/Views/AuditLogView.swift`: pushed from a new
   "Audit log" row in `SystemView` (its own `Section` footer explaining
   what the log is: the hub's append-only record of who did what — copy in
   the same register as the existing Units/sign-out footnotes). The view:
   - fetches `audit(limit: 200)` on `.task`, newest first (verify server
     order; sort by `occurred_at` descending client-side if unordered);
   - each row: `category` as a caption-weight badge, `actor` + `subject`
     line in `Theme.primaryText`, device name via
     `DeviceCatalog.name(for:)` when `device_id` is set, relative age via
     `RelativeAge.describe(from:)` under it;
   - category filter as a toolbar `Menu` whose options are the categories
     present in the fetched page plus "All" (client-side filter of the
     fetched page — a second server query per category is not needed for
     v1);
   - §7.1 states: loading (`ProgressView`), empty ("No audit events"),
     error with the thrown message and a Retry button. Error text is amber
     (`Theme.attention`), never red — a failed fetch is not a safety event.
   - List styling matches `SystemView` (same `List`/`reefBackground`
     idiom); no pagination in v1; limit 200 stated in the section footer
     ("most recent 200 events").
3. No new kit logic worth unit-testing beyond what exists (the client
   method is generated-code plumbing; view is SwiftUI). Build cleanly.
4. Commit: `feat(system): UX-2 audit log view`.

## Task 5 — UX-1: light mode

The brief (§2) says "Light mode supported, secondary"; the binary pins dark
twice: `.preferredColorScheme(.dark)` at `BellasReef/BellasReefApp.swift:39`
AND `UIUserInterfaceStyle: Dark` in `project.yml` (Info.plist properties).
Ruling: implement light mode. Dark remains primary by design intent, not by
pin.

1. Restructure `Theme.swift`: introduce a `Palette` struct holding the ten
   colour roles as plain RGB components (`base`, `surface`, `surfaceRaised`,
   `primaryText`, `secondaryText`, `tertiaryText`, `accent`, `attention`,
   `safety`, `silence`), with `Palette.dark` (the existing values, verbatim
   — including the 4.60:1 tertiaryText story, whose comment moves with it)
   and `Palette.light` (new values, same semantic hues adapted for a light
   ground: cool near-white blue-grey base — not pure white, the same
   "water, not paper" reasoning as dark's not-pure-black — white-ish
   raised surfaces, dark blue-grey text ramp, darkened teal/amber/violet;
   safety red kept recognisably the same red). The public `Theme.base` etc.
   become dynamic: `Color(UIColor { trait in ... })` resolving dark/light
   per `userInterfaceStyle`, so all existing call sites compile unchanged.
   Keep `HealthTone` and `reefBackground()` as-is.
2. Contrast tests drive the light values: extend `ThemeTests` (replace the
   placeholder) with a WCAG relative-luminance contrast function and
   assertions for BOTH palettes: primaryText, secondaryText, tertiaryText
   ≥ 4.5:1 against `base` AND against `surface`; attention/safety/silence
   ≥ 4.5:1 against `base` where used as text (alert banner names use
   attention-on-surfaceRaised — include that pair); accent ≥ 3:1 against
   `base` (non-text UI). Tune `Palette.light` numbers until green — the
   values in this plan are starting points, the tests are the authority.
3. Remove both dark pins (`BellasReefApp.swift:39`,
   `UIUserInterfaceStyle` in `project.yml`), regenerate the project
   (`xcodegen generate`), and grep the app for any other
   `preferredColorScheme` / `colorScheme` assumptions (e.g. opacity-based
   overlays that only make sense on dark — `Theme.accent.opacity(0.8)`
   sparkline stroke, `Theme.attention.opacity(0.5)` banner border — these
   inherit the adapted base colours and need no change unless the visual
   pass says otherwise).
4. Run kit tests (contrast suite) and build the app. The screen-by-screen
   simulator pass in both appearances is the controller's acceptance step,
   not this task's — but the task must leave the app building and tests
   green.
5. Commit: `feat(theme): UX-1 light mode — adaptive palette, dark stays
   primary`.
