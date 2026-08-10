#!/usr/bin/env bash
# Re-pin the vendored contracts from the backend's CI artifact.
#
# The app never edits these by hand. A refresh that changes generated types
# shows up as compile errors in BellasReefKit, which is exactly what PRD G3 is
# for — drift is a build failure, not a runtime surprise on a tank.
set -euo pipefail
cd "$(dirname "$0")/.."

BACKEND_REPO=viperdavethesnake/bellas-reef
RUN_ID="${1:-}"

if [[ -z "$RUN_ID" ]]; then
    RUN_ID=$(gh run list -R "$BACKEND_REPO" --branch main --status success \
             --limit 1 --json databaseId -q '.[0].databaseId')
    echo "using latest green run on main: $RUN_ID"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh run download "$RUN_ID" -R "$BACKEND_REPO" -n client-contracts -D "$tmp"

cp "$tmp/openapi.json" Contracts/openapi.json
cp "$tmp/stream-frames.schema.json" Contracts/stream-frames.schema.json
# The generator plugin reads the spec from the target's own directory.
cp "$tmp/openapi.json" BellasReefKit/Sources/BellasReefAPI/openapi.json

echo "pinned run $RUN_ID"
git --no-pager diff --stat -- Contracts BellasReefKit/Sources/BellasReefAPI/openapi.json || true
echo
echo "Update Contracts/PINNED.md, then rebuild. Compile errors here are the"
echo "contract telling you something changed."
