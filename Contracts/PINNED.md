# Pinned contracts

These are **not** edited here. They are downloaded from the backend's CI
artifact and committed, so a build is reproducible and a contract change is a
reviewable diff rather than something that shifts under the app.

| | |
|---|---|
| Backend commit | `0046d9f` |
| CI run | exported locally from `9c3dbba`; re-pin from the artifact once that run is green |
| Pinned on | 2026-08-10 |
| OpenAPI | 3.1.0, 17 paths |
| Contracts version | 2.1.0 |
| Frame schema | v1 |

## Refreshing

```sh
./scripts/pin-contracts.sh          # latest green run on main
./scripts/pin-contracts.sh <run-id> # a specific run
```

A refresh that changes generated types shows up as compile errors in
`BellasReefKit`. That is the point — PRD G3.
