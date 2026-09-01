#!/usr/bin/env bash
# Fail when a raw Swift error looks likely to reach user-visible text
# instead of going through `HumanError.describe`.
#
# This bit the bench twice: a `"\(error)"` interpolation (a full
# `swift-openapi` `ClientError` dump — operationID, request, response, body)
# landed straight in a `ContentUnavailableView`, and a `StreamError` payload
# carried a raw `DecodingError` dump onto the Tank status pill. Both were
# caught by hand, on a rendered screen, well after the code that caused them
# had shipped and been reviewed — the presenter doc (`HumanError.swift`'s own
# comment) is not where an author looks while writing a `catch` block. This
# check is the enforcement `HumanError.swift` doesn't have on its own: it
# runs the pattern the second bench finding was found by, every time, in CI.
#
# Forbidden, on any line outside the exclusions below:
#   \(error            -- a raw error interpolated straight into a string
#   String(describing: error  -- the same thing spelled out
#   .localizedDescription     -- Swift's default Error->NSError bridge text
#   error.description         -- a bare error's own (usually synthesized,
#                                 dump-shaped) CustomStringConvertible
#
# Exclusions, each narrow and load-bearing:
#   - HumanError.swift itself: it is the one file allowed to look at an
#     error's raw text, because turning it into a sentence is its entire job.
#   - Test directories: fakes and fixtures throw whatever is convenient for
#     the test; nobody reads it on a screen.
#   - A line whose Swift is a `log.` call: the raw error going to the log is
#     the other half of the idiom ("raw errors go to the log; people get a
#     sentence" -- HumanError.swift's own doc comment), not a violation of it.
#   - A line comment (`//...` or `///...`, once leading whitespace is
#     stripped): several doc comments in this codebase narrate the *history*
#     of this exact defect class and necessarily quote the forbidden shapes
#     in prose.
#   - A line carrying the literal marker `no-raw-error:`, but ONLY when that
#     same line also matches one of the forbidden patterns above. A marker
#     that doesn't sit on a flagged line is itself a failure — it exempts
#     nothing, so it is either stale or was pasted onto the wrong line, and
#     either way it must be removed. This is what stops the marker from
#     becoming a blank check: `// no-raw-error: TODO` above a future
#     `problem = "\(error)"` would otherwise silently defeat the whole
#     script.
#
#     A second, independent guard backs this up: every marker use, valid or
#     not, is counted, and the total must equal EXPECTED_MARKERS exactly. A
#     marker on a genuine new violation would pass the "must match a
#     forbidden pattern" check above (it does match — that's the violation
#     it's exempting) and so would otherwise sail through silently; the count
#     assertion is what forces raising EXPECTED_MARKERS to be a reviewed,
#     diffed decision rather than a quiet opt-out.
#
#     The one sanctioned exception in the tree today is in
#     `BellasReefKit/Sources/BellasReefKit/TankMonitor.swift`: the
#     `.contractMismatch` branch does
#     `connection = .contractMismatch(error.description)`, reading
#     `StreamClient.StreamError`'s own hand-authored `.description` directly
#     rather than through `HumanError.describe` — `HumanError.swift`'s own
#     `StreamError` pass-through comment explains why, and
#     `StreamClient.decode`'s payload is already the short, human phrase.
#     Routing it through `describe` a second time would erase that detail
#     for nothing. Named by file and shape here, not by line number — a line
#     number in this file already drifted once as the surrounding code grew.
set -euo pipefail
cd "$(dirname "$0")/.."

# Raise this only as a reviewed, diffed decision, and say in the commit which
# line earned it and why — see the marker exclusion above.
EXPECTED_MARKERS=1

exclude_file="BellasReefKit/Sources/BellasReefKit/HumanError.swift"
pattern='\\\(error[.)]|String\(describing: error[.)]|\.localizedDescription|error\.description'
marker='no-raw-error:'

violations=0
marker_count=0
marker_locations=""

while IFS= read -r -d '' file; do
    [[ "$file" == "./$exclude_file" || "$file" == "$exclude_file" ]] && continue
    [[ "$file" == *"/Tests/"* ]] && continue

    line_no=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))

        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" == //* ]] && continue

        has_marker=0
        [[ "$line" == *"$marker"* ]] && has_marker=1

        matches=0
        [[ "$line" =~ $pattern ]] && matches=1

        if [[ "$has_marker" -eq 1 ]]; then
            marker_count=$((marker_count + 1))
            marker_locations="${marker_locations}${file#./}:${line_no}
"
            if [[ "$matches" -eq 0 ]]; then
                echo "::error file=${file#./},line=${line_no}::no-raw-error marker on a line the fence would not flag — remove it"
                violations=$((violations + 1))
            fi
            # A valid marker (matches == 1) exempts this line from the
            # ordinary violation check below, whether or not it also
            # happens to be a `log.` line.
            continue
        fi

        [[ "$line" == *"log."* ]] && continue

        if [[ "$matches" -eq 1 ]]; then
            echo "::error file=${file#./},line=${line_no}::raw error text may reach a screen — route through HumanError.describe, or log it via a 'log.' call"
            violations=$((violations + 1))
        fi
    done < "$file"
done < <(find BellasReef BellasReefKit -name '*.swift' -print0)

if [[ "$marker_count" -ne "$EXPECTED_MARKERS" ]]; then
    echo "::error::no-raw-error marker count is ${marker_count}, expected ${EXPECTED_MARKERS}. Raising this is a reviewed decision — name the sanctioned line in the commit. Markers found at:" >&2
    if [[ -n "$marker_locations" ]]; then
        printf '%s' "$marker_locations" | while IFS= read -r loc; do
            [[ -n "$loc" ]] && echo "  $loc" >&2
        done
    else
        echo "  (none)" >&2
    fi
    violations=$((violations + 1))
fi

if [[ "$violations" -gt 0 ]]; then
    echo "no-raw-errors: ${violations} violation(s) found" >&2
    exit 1
fi

echo "no-raw-errors: clean"
