// Bella's Reef iOS — closed source.
//
// This is the only hand-written file in this target, and it contains no code.
//
// Everything else here is produced at build time by swift-openapi-generator
// from `openapi.json`, which is vendored from the backend's CI artifact and
// pinned (see ../../../Contracts/PINNED.md). That is PRD G3: a contract change
// becomes a compile error rather than a runtime surprise on a tank.
//
// The file exists because SwiftPM rejects a target with no Swift sources, even
// when a build plugin supplies them all.
//
// **Do not add API types here.** If something is missing, it is missing from
// the spec, and the fix belongs in the backend. Hand-writing it would defeat
// the only mechanism that keeps this client honest.
//
// Generated surface:
//   * `Client`             — the REST client
//   * `Components.Schemas` — request/response models, and the WebSocket frame
//                            types the backend folds into components so they
//                            are generated rather than hand-written
//                            (PRD v1.3 G3 footnote).
