# Pinned contracts

These are **not** edited here. They are downloaded from the backend's CI
artifact and committed, so a build is reproducible and a contract change is a
reviewable diff rather than something that shifts under the app.

| | |
|---|---|
| Backend commit | `3b01443` |
| CI run | [31357262810](https://github.com/viperdavethesnake/bellas-reef/actions/runs/31357262810) |
| Pinned on | 2026-08-10 |
| OpenAPI | 3.1.0, 13 paths |
| Frame schema | v1 |

## Refreshing

```sh
./scripts/pin-contracts.sh          # latest green run on main
./scripts/pin-contracts.sh <run-id> # a specific run
```

A refresh that changes generated types shows up as compile errors in
`BellasReefKit`. That is the point — PRD G3.
