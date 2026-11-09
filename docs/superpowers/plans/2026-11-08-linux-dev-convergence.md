# Linux L0 Dev Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage **L0** only — honest Linux Flutter **desktop dev** diagnostics (`oka doctor`) and CI-gated E2E for `oka run dev --platform linux` (reload, restart, assets, cleanup).

**Architecture:** Parse-and-delegate doctor lines (ADR-0015) in `packages/oka` with **bounded** tool probes via `oka_core.runBoundedProcess` (same discipline as `universal_tooling_runtime`, no sibling-repo dependency); Linux L0 gates are **Dart-owned** (`lib/src/gate/` + `tool/gate_linux_dev.dart`) with shell entrypoints as bootstrap only. Preserves real `oka run dev --platform linux` (not raw `flutter run` alone). CI job `linux-desktop-dev` with Flutter + GTK + display + debug warm build.

**Tech Stack:** Dart 3.13 workspace, bash gates, Flutter stable linux desktop embedder.

**Internal gate APIs:** `lib/src/gate/linux_dev_gate.dart` and `lib/src/gate/owned_dev_session.dart` are intentionally **not** exported from `package:oka_dart_kernel/oka_dart_kernel.dart`. Callers inside this repo use `package:oka_dart_kernel/src/gate/...` until the declarative refactor (**R2–R8**: declarative device/run spec set before the run, single supervision via `oka_process`, no output parsing) decides their public shape.

## Global Constraints

- Base: `main` @ `0ffa098e7479ef18b01b24828e9857cf952cc9d9` (post PR #16 merge).
- **No L1–L3 code** in this PR (no `oka build linux`, snap pack, store upload).
- **No** snap store upload, name registration, or credential collection in L0.
- One Ubuntu x64 CI proof ≠ all Linux distros/arm64 hosts.
- Skip/fail gates loudly when GTK/display/flutter linux missing — never claim green without E2E.
- Branch: `cursor/linux-l0-dev-convergence-1015`.

---

## Later stages (Anton-approved roadmap; not implemented here)

### L1 — Release bundle (delegated compile + provenance)

- `LinuxBuildTarget` / `oka build linux` delegates `flutter build linux` on **native** host arch.
- `oka-provenance.json` on bundle path; artifact store tar staging.
- **Acceptance:** ubuntu-amd64 CI builds bundle; parser unit tests; doctor reports arch.

### L2 — Snap pack + verify (no store)

- Typed `snap/` layout generation; `snapcraft pack` locally/CI (LXD when present).
- `oka verify linux-snap`; `snap install --dangerous` smoke.
- **Acceptance:** `.snap` artifact + verify report; no upload.

### L3 — Snap Store publish (**real operations, convenient DX**)

Product requirement (not permission to publish a specific app in agent runs):

- **Real** credential-gated `snapcraft upload` and **channel release** (`stable`/`candidate`/progressive promotion), plus **rollback** via `snapcraft release` where the store API supports it — same operation surface as dry-run previews (ADR-0014: dry-run plans the **identical** steps with zero side effects; it is **not** a substitute for implementing live upload/release).
- **Convenience:** one-time guided setup (snap name, account linkage doc), persistent **non-secret** config in project (`targets:` / credential **paths** per ADR-0023), minimal repeat prompts, actionable doctor + publish receipts (revision, channel, % progressive), safe retries/partial-success handling, `OKA_*` / CI non-interactive paths.
- Reuse `PublishTarget` + `oka run publish-snap-*` naming; verify snapcraft CLI behavior in implementation (do not assume from design-only research).
- **Acceptance:** dry-run passes without creds; opt-in integration records argv fixtures; human/CI with creds completes upload+release in staging channel; agent runs never hold store tokens.

**OTA boundary (unchanged):** strict Snap revisions owned by snapd; `oka ship` / JIT dev for non-snap and `oka run dev` sessions.

---

## Task 1: Portable gate `sed` + plan commit

- [ ] Fix `restore_marker` in `packages/oka_dart_kernel/tool/gate_lib.sh` for GNU sed (Linux) and BSD sed (macOS).
- [ ] Commit plan file.

**Verify:** `bash -n gate_lib.sh`.

---

## Task 2: Linux desktop doctor (TDD)

- [ ] Add `packages/oka/lib/src/doctor/linux_desktop_doctor.dart` with:
  - `LinuxDesktopDoctorReport` (`blocking`, `lines`, `capabilities` map).
  - Checks: host OS, native arch (`uname` / `Platform.version`), Flutter on PATH, `flutter devices` contains `linux`, GTK dev libs probe (`pkg-config gtk+-3.0` or debian package hints), display (`DISPLAY` / `WAYLAND_DISPLAY`), capability summary for `oka run dev --platform linux`.
  - On non-Linux hosts: advisory section, not blocking.
- [ ] `packages/oka/test/linux_desktop_doctor_test.dart` — fixture stdout for devices/doctor parsing.
- [ ] Wire `packages/oka/lib/src/cli/doctor_command.dart` block `[Linux Desktop Dev (L0)]`.
- [ ] Export if needed via `package:oka/oka.dart` barrel (optional).

**Verify:** `cd packages/oka && dart test test/linux_desktop_doctor_test.dart`

---

## Task 3: Dart Linux reload gate

- [x] `LinuxDevGate.runReloadLeg` — probes file, reload probe flip, `Restarted application` + `restart: OK`.
- [x] `OwnedDevSession` teardown (identity-gated tree stop; no `pkill -f` patterns).
- [ ] Thin `gate_run_dev_linux.sh` → `gate_linux_dev.dart --leg reload`.

**Verify:** `OKA_LINUX_DEV_GATE_USE_XVFB=1 bash packages/oka_dart_kernel/tool/gate_run_dev_linux.sh`

---

## Task 4: Dart Linux assets gate

- [x] Delta + asset sync + evict JSON receipts + post-`R` VM fingerprint verify.
- [x] Unit tests for owned-session teardown (`test/owned_dev_session_test.dart`).
- [ ] Thin `gate_dev_assets_linux.sh` → `gate_linux_dev.dart --leg assets`.

**Verify:** full convergence script on Linux desktop host.

---

## Task 5: Docs + capability matrix

- [ ] Update `docs/guides/live_update.mdx` linux row + pointer to gates.
- [ ] Short note in `docs/evidence/` or extend bounded-fixes slice with L0 evidence template.

**Verify:** `tool/contracts/check_docs_drift.dart` / `check_contracts.sh`.

---

## Task 6: CI job `linux-desktop-dev`

- [ ] `.github/workflows/ci.yml`: job on `ubuntu-latest` with `subosito/flutter-action`, `sudo apt-get install` gtk/clang/ninja, `xvfb-run` or `:99` display, env `OKA_GATE_LINUX_DEV=1`, run both gates.
- [ ] Document versions in job log / evidence file output.

**Verify:** CI green on PR.

---

## Task 7: Final verification + PR

- [ ] `dart analyze`
- [ ] `dart test` (root) + `packages/oka` targeted
- [ ] `bash tool/contracts/check_contracts.sh`
- [ ] Self-review diff; open PR via ManagePullRequest.

---

## Evidence to record in PR body

- HEAD SHA, host arch (x86_64), Flutter version from gate job.
- Gate logs: probe `b -> c`, asset fingerprint verify, `q` clean exit.
- Explicit **limitations:** arm64 desktop, non-Ubuntu distros, headless without xvfb not supported for E2E.
