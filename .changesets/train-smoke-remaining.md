---
'oka': patch
'oka_android': patch
'oka_app_gallery': patch
'oka_artifacts': patch
'oka_conformance': patch
'oka_desktop': patch
'oka_google_play': patch
'oka_huawei': patch
'oka_rustore': patch
'oka_service': patch
'oka_supervisor': patch
'oka_web': patch
---

**Release-train smoke cut, part 2: explicit patch bumps for the 12
published packages the core cascade does not reach.** The engine's
dependent cascade is constraint-driven — caret constraints absorb a
patch bump of `oka_core`, so dependents are skipped by design
(`if (constraint.allows(newVersion)) continue;`). A full-train smoke
needs every package declared explicitly. Union with
`train-smoke-patterns.md` covers all 17 published packages; the three
unpublished ones (`oka_devices`, `oka_dart_kernel`, `oka_verify`) stay
out — they have no pub.dev automated-publishing config yet.
