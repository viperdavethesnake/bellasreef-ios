# iOS deferred-minors batch — 2026-09-01

Close the whole iOS minors backlog (the 2026-08-23 schedules-review pile and
the 2026-08-28 view pile) in one branch, so v0.2.0 graduates with no known
iOS minors. Every item was re-audited against `main` (`6d32bc4`) on
2026-09-01; the file:line evidence below is from that audit.

Spec: there is none beyond the findings themselves. The backend repo's
`docs/bellas-reef-ios-ux-review.md` §7.7 is the authority for alert copy
("the reading *and* the threshold, not 'alert'"). Rulings in this plan are
the controller's.

## Global constraints

- **TDD.** Every behaviour change lands with a test that failed first. Kit
  tests run with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -scheme BellasReefKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -skipPackagePluginValidation -skipMacroValidation -derivedDataPath build/DerivedData`
  (run from the repo root). Use `-only-testing:` to scope a run while
  iterating; run the whole Kit scheme before committing. Kit tests are
  Swift Testing (`@Test`, `#expect`), match the existing files.
- **The app must build** after every task:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project BellasReef.xcodeproj -scheme BellasReef -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation`.
  Without `DEVELOPER_DIR` nothing works from the CLI; without the two
  `-skip*` flags the OpenAPI plugin fails validation.
- Logic that a view needs tested moves **into Kit** (`BellasReefKit/Sources/BellasReefKit`)
  with a test in `BellasReefKit/Tests/BellasReefKitTests`. Views stay thin.
- No hand-written API bindings; the generated client is the only transport.
- Swift 6 strict concurrency; no new package dependencies.
- Home-hobbyist scope: one operator, one hub. No settings, no feature flags,
  no abstraction beyond what the fix needs.
- Conventional commits, one commit per task (or a few, each green).
- Do not touch files outside a task's list unless the build forces it; say
  so in the report if it does.

## Task 1 — Kit: ScheduleCurve, ScheduleLibrary, HubClient test fences

Files: `BellasReefKit/Sources/BellasReefKit/ScheduleCurve.swift`,
`BellasReefKit/Tests/BellasReefKitTests/ScheduleCurveTests.swift`,
`ScheduleLibraryTests.swift`, `HardwareClientTests.swift`,
`ScheduleClientTests.swift` (and `CredentialRejectionTests.swift` for the
401 pattern to copy).

1. **`wireTime(fromSeconds: 86400)` → "24:00:00"** (`ScheduleCurve.swift:134-136`
   emits it; `:129` rejects hour 24 on parse; `plotPoints` mints an 86_400
   point at `:84`). Ruling: `wireTime(fromSeconds:)` clamps 86_400 to
   `"23:59:59"`? No — that lies. Make the asymmetry explicit instead: keep
   the plot endpoint (it is a plot coordinate, not a wire value) and add a
   test asserting `wireTime(fromSeconds: 86_400)` round-trips through the
   parser as `nil` *and* a doc comment on `wireTime` saying 86_400 is
   plot-only. If the function is reachable from any non-plot caller with
   86_400 (grep), guard there.
2. **Calendar rebuilt per `secondsOfDay` call** (`ScheduleCurve.swift:59-64`;
   called per chart tick from `ScheduleChart.swift:49,55`,
   `LightingView.swift:330`). Store the configured `Calendar` alongside
   `zone` at init. Test: `secondsOfDay` result unchanged for the existing
   zoned test inputs (behaviour fence — this is a perf refactor).
3. **No DST pin test** (`ScheduleCurveTests.swift` is UTC throughout except
   `:58-66`). Add `America/Los_Angeles` assertions on `secondsOfDay` /
   `duty(at:)` for the 2026 spring-forward day (2026-03-08, 02:00 →
   03:00) and the fall-back day (2026-11-01, 01:00 repeats): a wall-clock
   time after the gap/fold maps to the seconds-of-day the wall clock reads,
   not an offset-shifted value. Write the expected values from the calendar
   maths, not from running the code.
4. **Two plotPoints assertions compare a value to itself**
   (`ScheduleCurveTests.swift:75` and `:86`). Replace each with an
   independently computed expectation (the pattern at `:74` is right).
5. **ScheduleLibrary create/update refusal fence**: `ScheduleLibraryTests.swift:71-126`
   covers delete-404 / assign-409 / unassign-404. Add the same
   "did not re-read" fence for `create` and `update` refusals
   (`.nameTaken`, `.curveRejected`, `.unknownSchedule` —
   `ScheduleLibrary.swift:58-72`).
6. **HubClient `hardware()` / `schedules()` non-happy paths**
   (`HubClient.swift:255-263`, `:555-564`; tests only cover 200). Add a
   401 case (mirroring `CredentialRejectionTests.swift:49-70` — assert the
   revocation behaviour that test asserts, whichever it is) and an
   undocumented-status case for each wrapper, in `HardwareClientTests.swift`
   and `ScheduleClientTests.swift`.

## Task 2 — Kit `ScheduleDraft` + ScheduleEditorView

Files: new `BellasReefKit/Sources/BellasReefKit/ScheduleDraft.swift`, new
`BellasReefKit/Tests/BellasReefKitTests/ScheduleDraftTests.swift`,
`BellasReef/Views/ScheduleEditorView.swift`.

1. **Hoist editor rules into Kit.** `ScheduleEditorView.swift:79-86`
   (`validationText`), `:67-77` (`draftCurve`), `:216-228` (`save` rebuilds
   the request) duplicate `ScheduleCurve.swift:31-39`. Add a Kit value
   `ScheduleDraft` holding `name` and `[DraftPoint]` (seconds-of-day +
   duty percent) with:
   - `validate() -> Result<ScheduleRequest, String>` carrying the existing
     rules verbatim (non-empty name, ≥2 points, no duplicate times, duty
     range) and the wire encoding the view does today — the messages the
     view shows now are the messages `.failure` carries.
   - `static func secondsOfDay(from date: Date) -> Int` and
     `static func date(secondsOfDay: Int) -> Date`, both against a **fixed
     UTC reference day** (`Date(timeIntervalSinceReferenceDate: 0)`, GMT),
     so the round trip is identical on every calendar day.
   - `func nextFreeTime() -> Int?` — the `addPoint` rule: `latest + 3600`
     capped at `86_340`; if that minute is taken, the nearest free minute
     at or below the cap; `nil` when no minute ≤ 86_340 is free.
   Tests: each rule; the DST case (a 02:30 point converted on any day
   yields 9_000 s and back); `nextFreeTime` at the cap with the cap taken
   returns the free minute below it; `nil` when 0…86_340 are all taken (build
   that draft programmatically).
2. **ScheduleEditorView adopts it.** `timeBinding` (`:192-206`) uses the two
   static converters and the `DatePicker` gets
   `.environment(\.timeZone, TimeZone.gmt)` so the picker and the converters
   agree. `addPoint` (`:210-214`) uses `nextFreeTime()`; the Add control is
   disabled when it returns `nil`. `validationText`/`draftCurve`/`save` use
   `validate()`; no rule text remains in the view.
3. **`schedule-point-duty` identifier** (`:118`, inside `ForEach($draft)` at
   `:104`) becomes `"schedule-point-duty-\(index)"` with the row's stable
   index (ruling: index, not the fresh-UUID `DraftPoint.id` at `:25`).
4. Update the "editor validation duplicates Kit rules" comment if one exists.

## Task 3 — Views: Tank hold banner, alert phrase, MiniDayCurve floor, LightDetailView

Files: `BellasReef/Views/TankView.swift`, `BellasReef/Views/LightingView.swift`,
`BellasReef/Views/MiniDayCurve.swift`, `BellasReef/Views/ScheduleChart.swift`,
`BellasReef/Views/LightDetailView.swift`, `BellasReef/Views/Theme.swift` (or
wherever `Theme` lives), Kit: `Dimming.swift`, new `AlertPhrase.swift` +
`AlertPhraseTests.swift`, `LightingCardsTests.swift` if the label helper
lands in Kit.

1. **TankView "Held at"** (`TankView.swift:709-715`): the string lacks the
   transition word and `expires_in_s` is a frame snapshot that freezes when
   the stream is quiet (`LightingCards.swift:26-31` warns against exactly
   this). The correct pattern already exists at `LightingView.swift:366-372`
   (`TimelineView(.periodic(by: 5))` + `Self.label(for: hold.transition)`,
   helper at `:723-726`). Move the transition label helper to **one** shared
   place (Kit, next to the transition type, with a one-line test) and use
   it from both views. Wrap the hold label in a `TimelineView(.periodic(by:
   5))` and compute remaining from `expires_at` vs `context.date` via the
   existing `formatRemaining` (`:749-753`). The spoken label (`:727-737`)
   gets both too. Format: `Held at 15% · Snap · 12 min left` — match
   LightingView's wording exactly so the two surfaces read the same.
2. **Alert phrase gap** (`TankView.swift:240-243` returns `"Out of range"`
   when `raised_value`/`threshold`/`unit` are nil — all optional on the wire;
   `:245-247` prints the raw unit token for non-`degC`). Move the headline
   into Kit as `AlertPhrase.headline(...)` mirroring `AuditPhrase`:
   - all fields present: the existing sentence, unchanged;
   - missing value or threshold: `"<sensor name> outside its thresholds"`
     (name is always available) — never the bare "Out of range";
   - units: `degC`/`degF` as today; `pH` → `pH`; `ppm` → `ppm`; `percent` →
     `%`; anything else → the raw token (ruling: no invented symbols).
   - `AuditPhrase.swift:66`'s `default: return action` and the
     `alertClass == .silence ? .silence : .threshold` fall-through at
     `HubClient.swift:721` / `HistoryModel.swift:360-362`: ruling — leave
     the class mapping as is (two classes exist on the wire today; a third
     is a contracts change and gets its own phrase then). Note this in the
     report, do not change it.
   Tests in `AlertPhraseTests.swift`: each branch above.
3. **MiniDayCurve floor band** (`MiniDayCurve.swift:21-52` draws stroke +
   now dot only; `ScheduleChart.swift:28-33` shades `0...Dimming.minUsableDuty * 100`
   at `Theme.tertiaryText.opacity(0.12)`). Add the same band under the
   `Path`, sourced from `Dimming.minUsableDuty`. Hoist the band's tint and
   opacity into one `Theme` constant (`Theme.floorBand` or similar) used
   by both charts so they cannot drift. No new Kit test unless a descriptor
   lands in Kit; if one does, one test on its range.
4. **LightDetailView double merge** (`LightDetailView.swift:22-28` computed
   `card` evaluated at `:33` and `:74`). Bind once at the top of `body`
   (`let card = card`) and use it for the title. No test (view-only).

## After the branch merges (controller, not a task)

- Delete the `ios-schedules-deferred-minors` memory; update
  `bellasreef-current-state`.
- The UX-review design conversations (B3, C4, C5, Tier D) are **not** in
  this plan — they are David's rulings, listed separately.
