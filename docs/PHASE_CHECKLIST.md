# Phase Checklist — open work

Only items that need addressing live here. This is the **execution view**:
what + what gates it, per horizon. The human-facing "where oka is going and
why" is [start_here/roadmap.md](start_here/roadmap.md).

Completed phases are archived with their evidence:

- ADR-0013 (T0–T2), ADR-0014 (P0–P2), ADR-0015 (C0–C2), ADR-0011 (H0–H5),
  ADR-0010 typed config, ADR-0009 hybrid removal →
  [archive/PHASE_CHECKLIST_2026-09.md](archive/PHASE_CHECKLIST_2026-09.md)
- ADR-0006/0007/0008 (composition API, self-resolving builds, dep-plan
  dry-run) →
  [archive/PHASE_CHECKLIST_adr0006-0008.md](archive/PHASE_CHECKLIST_adr0006-0008.md)

A phase is done only when its tests and evidence exist (see `AGENTS.md`).
Nothing below carries a checkbox — items move out of here into an archive
with evidence, not into a checked box.

## Now (unblocked, code-ready)

- **Real store uploads (Play + AppGallery).** Flip `PlayPublishTarget` /
  `HuaweiPublishTarget` from dry-run to a real upload with maintainer
  service-account / AGC credentials and record one live upload each as
  evidence. Why now: P1/P2 dry-run plans, full offline conformance suites,
  and flow tests exist — only credentials block; the synthetic test key
  guards nothing.
- **CI emulator tier for the dev-loop e2e.** Reproduce the H0/H2/H3
  headless-emulator chain (`oka run device` → `oka dev --json` → reload /
  restart / detach) as a CI job on a KVM-capable runner. Why now: the
  evidence is machine-local; a CI tier turns it into a regression gate for
  the whole dev loop.
- **Doctor secret-audit hardening (if gaps surface).** Extend
  `secretishKeyPatterns` / `auditDartDefines` coverage where real-world
  dart-define keys slip through the pattern table. Why now: the audit is
  live and cheap to extend, but pattern tables need evidence of real gaps
  before growing.
- **`oka cache gc` polish: age/size reporting.** Make `oka cache gc`
  report reclaimable bytes and last-use age before deleting, so purging is
  inspectable like everything else. Why now: the store layout
  (`oka_store.json` per entry) already records what's needed; this is pure
  reporting on existing data.
- **Leakage-ratchet final exception: the `--skip-badging` flag name.**
  Decide whether to keep it as public CLI surface or deprecate it toward
  the typed `DeviceTarget`/`AndroidBuild` config and empty the ratchet.
  Why now: it is the only remaining exception in
  `test/adr0015_cli_platform_leakage_gate_test.dart`; either closing or
  ratifying it lets the gate go fully green-by-construction.

## Next (needs a checkpoint / ADR)

- **iOS platform candidate.** First second-platform: an `oka_ios` package
  with typed `IosBuild` + pipeline, per the north-star criteria. Gate:
  design fork → checkpoint + ADR before coding (which parts of
  `flutter assemble`/Xcode CLI tools oka owns vs delegates; no-Gradle law
  needs an iOS analogue).
- **RuStore / Yandex publish targets.** `oka_rustore` / `oka_yandex`
  following the `oka_play`/`oka_huawei` package shape (`PublishTarget` +
  conformance suite + injectable client). Gate: same checkpoint/ADR
  question — target packages as a productized third-party extension point
  vs first-party additions — before the pattern gets copied twice more.
- **`oka cache gc` scheduling / daemon question.** Whether gc stays a
  manual verb or gains a scheduled/daemon form. Gate: ADR — a background
  process conflicts with oka's no-daemon posture (ADR-0001) and needs an
  explicit decision, not a default.
- **Hot-reload CI tier.** Promote the one-shot emulator e2e (Now) into a
  repeatable `oka dev` session tier (watch-loop classification, reconnect
  paths). Gate: needs the CI emulator tier to exist and a decision on
  runtime budget (session tests are minutes, not seconds).

## Later (north-star alignment)

- **Second/third platform beyond iOS.** Each new platform per the
  north-star criteria: typed values, validated pipelines, no hidden glue,
  agent-operable from oka's messages alone. Gate: platform evidence (the
  iOS ADR outcome) plus a per-platform checkpoint; nothing starts on
  vibes.
- **Distribution-target conformance for third-party package authors.**
  Expose the ADR-0014 conformance suite (`oka_conformance`) as the
  contract third parties satisfy to ship `PublishTarget` packages. Gate:
  depends on the Next checkpoint on target packages being first-party vs
  an ecosystem surface.
