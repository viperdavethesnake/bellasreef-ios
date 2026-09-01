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
#   - A line carrying the literal marker `no-raw-error:`, immediately
#     followed by a comment naming why. One line in the tree currently uses
#     this: `TankMonitor.swift`'s `.contractMismatch` branch reads a
#     `StreamError`'s own hand-authored `.description` directly, by design
#     (see `HumanError.swift`'s `StreamError` pass-through, and the comment
#     at that call site) -- routing it back through `HumanError.describe`
#     would erase the one useful detail a contract-mismatch message has. The
#     marker keeps that exception visible and grep-able rather than silent.
set -euo pipefail
cd "$(dirname "$0")/.."

exclude_file="BellasReefKit/Sources/BellasReefKit/HumanError.swift"
pattern='\\\(error[.)]|String\(describing: error[.)]|\.localizedDescription|error\.description'

violations=0

while IFS= read -r -d '' file; do
    [[ "$file" == "./$exclude_file" || "$file" == "$exclude_file" ]] && continue
    [[ "$file" == *"/Tests/"* ]] && continue

    line_no=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))

        [[ "$line" == *"log."* ]] && continue
        [[ "$line" == *"no-raw-error:"* ]] && continue

        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" == //* ]] && continue

        if [[ "$line" =~ $pattern ]]; then
            echo "::error file=${file#./},line=${line_no}::raw error text may reach a screen — route through HumanError.describe, or log it via a 'log.' call"
            violations=$((violations + 1))
        fi
    done < "$file"
done < <(find BellasReef BellasReefKit -name '*.swift' -print0)

if [[ "$violations" -gt 0 ]]; then
    echo "no-raw-errors: ${violations} violation(s) found" >&2
    exit 1
fi

echo "no-raw-errors: clean"
