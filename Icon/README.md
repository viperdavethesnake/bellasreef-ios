# App icon

## What is here

| File | What it is |
|---|---|
| `coral-front.svg` | Front coral, flat `#2DD4BF`, one path |
| `coral-rear.svg` | Rear ghost coral, flat `#17706A` — the **union** silhouette, so placing it behind the front leaves exactly the visible ghost |
| `background.svg` | Solid `#0A1220` |
| `preview-1024.png` | The three composited flat, and the current shipping icon |
| `paths.json` | Raw traced path data, source of the SVGs |
| `icon-composer-wip/` | An unfinished `.icon` package — see below |

## How the trace was made

Top-left quadrant of the source grid, separated into two layers by luminance
(the front coral and the ghost occupy two clearly distinct luminance clusters,
with a gap between the 25th and 50th percentile), median-filtered to drop JPEG
speckle, then traced with potrace.

Fidelity against the source masks: **front 99.19% IoU, rear 99.47% IoU**. No
meaningful deviation from the source silhouette.

All baked shadows and blurs are gone — the source's soft drop shadow is not
reproduced, because Liquid Glass supplies depth at render time and a baked
shadow goes muddy in tinted and clear modes.

The rear layer is the union of both silhouettes rather than the ghost's visible
sliver. The ghost is an offset duplicate whose hidden part cannot be recovered
from a flat image, and the union renders identically once the front layer is on
top of it.

## Status: layered .icon is NOT wired up

The shipping icon is a conventional `AppIcon.appiconset` built from
`preview-1024.png`. It renders correctly, but it is **flat** — no light/dark/
tinted/clear variants, and no Liquid Glass layer separation.

`icon-composer-wip/AppIcon.icon` holds a hand-authored `icon.json` that `actool`
rejects:

    error: Exception while running actool: *** -[__NSPlaceholderArray
    initWithObjects:count:]: attempt to insert nil object from objects[0]

Three schema variants were tried (with and without `supported-platforms`, and
with SVG and PNG layer assets); all three produce the same crash, which means a
required key is missing rather than a value being malformed. Apple publishes no
schema for `icon.json`, and Xcode ships no sample `.icon` to copy from, so
finishing it by guesswork would be inventing library behaviour.

**To finish it (a GUI job, a couple of minutes):**

1. Open Icon Composer (Xcode ▸ Open Developer Tool ▸ Icon Composer).
2. New document, then drag in, bottom to top:
   `background.svg`, `coral-rear.svg`, `coral-front.svg`.
3. Confirm the group stacking, then export/save as `AppIcon.icon` at the repo
   root.
4. In `project.yml`, add `- path: AppIcon.icon` to the app target's `sources`.
   The `options.fileTypes."icon".file: true` entry is already there — without it
   XcodeGen walks into the package and adds each asset separately, which builds
   but produces no icon.
5. Delete `BellasReef/Assets.xcassets/AppIcon.appiconset`.
