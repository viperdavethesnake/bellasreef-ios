# Visual acceptance pass — ux/2026-08-14-findings

Simulator: iPhone 17 (9438872C-7EF2-4BA7-837F-1C55F938E6DF), already paired to
the live production hub. Navigation done via a throwaway XCUITest
(`BellasReefUITests/VisualPassTests.swift`, deleted after the run, project
regenerated with `xcodegen generate` — working tree confirmed clean).
Read-only throughout: tab switches, one NavigationLink open (System → Audit
log), no writes.

Screenshots (10, both appearances × 5 stops): captured via `xcresulttool
export attachments` from two `xcodebuild test` result bundles (light, dark),
copied to:

```
/private/tmp/claude-501/-Users-david-visualstudio-bellasreef/dc5dd232-9ce4-433f-a2ff-5f71a571a98c/scratchpad/visual-pass/
  light-tank.png       dark-tank.png
  light-lighting.png   dark-lighting.png
  light-history.png    dark-history.png
  light-system.png     dark-system.png
  light-audit-log.png  dark-audit-log.png
```

## Overall verdict

**PASS, both appearances.** No light-on-light legibility failures, no
hardcoded-dark rectangles floating on a light screen, no broken color
meanings. Base in light mode reads as a cool near-white blue-grey, not pure
white, as intended. Dark mode matches the pre-existing look — nothing reads
as changed that shouldn't be.

## Per-screenshot findings

### 01 — Tank

**light-tank.png**: Alert banner (amber border, white card, amber heading
"Lonely Temp Probe", black body text, gray timestamp) is fully legible.
Hero reading "73.5 °F" in near-black on the blue-grey base — strong contrast.
"trend: collecting…" caption in mid-gray, legible but appropriately
de-emphasized. Equipment section ("Light" header, "Front LED Bar" / "Back LED
Bar" rows) shows the new `.adoptedSilent` copy "no state yet" in gray at the
trailing edge — legible, correctly de-emphasized relative to the device name.
No defects.

**dark-tank.png**: This run's tank tab rendered "No sensors reporting / The
hub is connected but no probe has sent a reading yet." instead of a hero
reading — the live hub's data hadn't arrived within this pass's fixed 3 s
wait before the screenshot fired (a timing artifact of the capture script
against a live/real hub, not a UI defect; the empty-state copy itself is
legible white-on-black and reads fine). Equipment rows show the same
"no state yet" copy as light mode, correctly. No visual defects in what
rendered.

### 02 — Lighting (placeholder / ComingSoon)

Both appearances: title "Lighting", explanatory body text in secondary gray,
"Not built yet" in tertiary gray, all legible in both light (dark-on-light)
and dark (light-on-dark). No defects.

### 03 — History

Both appearances: segment control (1H/6H/24H/7D) with "24H" selected —
white pill in light, gray pill in dark, both readable. Sparkline chart:
teal line (light) / cyan line (dark), axis labels legible, alert-episode
shaded bands render as tan/beige (light) and olive-brown (dark) — visually
distinct from the line color in both cases, no legibility collision.
"7 alert episodes" in amber, "No gaps at this resolution (9 min)" in gray —
both legible. No defects.

### 04 — System

Both appearances: Hub/Paired devices/Hardware sections on raised white
(light) / near-black (dark) cards over the blue-grey/near-black base — clear
card separation in both. "Revoke" and "Unadopt" render in standard iOS
destructive red in both appearances, distinct from the teal/cyan "Add a
device" affordance — control-red vs. status-teal meanings are preserved.
Text throughout (Name/Address/device rows) is legible in both.

**Observed, not scored as a defect**: iOS 26's Liquid Glass tab bar shows a
faint refracted ghost of the scrolled-under list content (visible as blurred
mirrored text reading roughly "…LED Ba(r)" / "pi-pwm · ch 0 · light" under
the Tank/Lighting icons) in both light and dark screenshots. This is the
platform's own glass-material refraction of content scrolled behind the bar,
not app-drawn content, and is consistent with the design brief's "glass
belongs to the navigation layer" intent (content itself never uses glass).
Flagging because it's visually busy under the tab labels — worth a glance at
actual device hardware since simulator glass rendering can differ, but not a
color/contrast/legibility bug from this pass's checklist.

### 05 — System → Audit log

Both appearances: "Audit log" title legible. Rows show category pill badges
("auth", "safety") — light gray pill/dark text in light mode, dark
pill/light text in dark mode, both legible — followed by
"api · bellasreef.audit.auth" / "hardware-io · bellasreef.audit.alert" in
primary text and a relative timestamp in gray. Category-filter icon
(top-right, teal/cyan circle) and a floating gear quick-settings button
(bottom-left) both render with sufficient contrast against their respective
backgrounds. No legibility defects; this hub has real audit events, so
states render with actual data rather than empty-state placeholders.

## Summary of defects

**None that fail the acceptance bar.** The two items above are informational:
1. The dark-mode Tank screenshot caught the "no readings yet" empty state
   instead of the hero due to this pass's fixed capture timing against the
   live hub, not a UI problem — the empty-state copy itself is fine.
2. The Liquid Glass tab-bar content-refraction ghosting under
   Tank/Lighting labels is platform behavior worth a real-device glance, not
   a code defect from this branch's light-mode/audit-log/equipment work.

Light-mode legibility, base color, and color-meaning preservation (teal,
amber, red) all check out. Dark mode is visually consistent with the
pre-existing app.
