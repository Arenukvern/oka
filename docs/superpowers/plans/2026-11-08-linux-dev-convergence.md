# Linux L0 Dev Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage **L0** only — honest Linux Flutter **desktop dev** diagnostics (`oka doctor`) and CI-gated E2E for `oka run dev --platform linux` (reload, restart, assets, cleanup).

**Architecture:** Parse-and-delegate doctor lines (ADR-0015) in `packages/oka`; portable gate helpers in `gate_lib.sh`; extend `gate_run_dev.sh` + new `gate_dev_assets_linux.sh` using the **example** app and existing probe discipline; optional CI job `linux-desktop-dev` with Flutter + GTK + display.

**Tech Stack:** Dart 3.13 workspace, bash gates, Flutter stable linux desktop embedder.

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

## Task 3: `gate_run_dev.sh` linux leg

- [ ] Add `probes-linux.json` (same probe as macos).
- [ ] `leg linux` after macos/web when `OKA_GATE_LINUX_DEV=1` or always on Linux CI job.
- [ ] Env `OKA_SKIP_LINUX_DEV=1` to skip on hosts without desktop (main `test` job unchanged).

**Verify:** `OKA_GATE_LINUX_DEV=1 bash packages/oka_dart_kernel/tool/gate_run_dev.sh` on Flutter+GTK host.

---

## Task 4: `gate_dev_assets_linux.sh`

- [ ] Clone `gate_dev_assets.sh` discipline for `--platform linux`.
- [ ] Cleanup: `pkill_pattern` for `build/linux.*bundle/example` or flutter linux binary.
- [ ] Uses `example/` app (assets + feature.dart).

**Verify:** full script on Linux desktop host.

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
