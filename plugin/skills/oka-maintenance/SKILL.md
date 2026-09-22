---
name: oka-maintenance
description: >-
  Maintain Oka's Dart CLI and platform packages: composable builds, cache and
  session APIs, dependency resolution, architecture refactoring, release/docs
  contracts and no-Gradle Android validation. Use when changing Oka itself,
  reviewing capability boundaries or preventing mixed-responsibility files.
license: MIT
metadata:
  version: 1.4.0
  author: Arenukvern
compatibility:
  - dart
  - flutter
  - android-sdk
---

# Oka maintenance

Read the repository `AGENTS.md` map and relevant capability code/tests. Use for
Oka itself, including platform-neutral APIs and web sessions; ordinary Flutter
application UI work is outside this skill's scope.

## Workflow

1. Run `steward doctor --json` and `steward actions list --json`. Inspect intended
   actions with `steward action inspect <id> --json` before execution.
2. Read the active plan and relevant ADR. For architecture, persistence, CLI
   workflows or lifecycle changes, read [architecture.md](references/architecture.md).
3. Identify the implementation owner and preserved public contracts. Record a
   decision checkpoint/ADR before a design fork. Respect plan-only requests;
   otherwise implement authorized work without an extra approval ceremony.
4. Delegate disjoint files when useful, fixing shared signatures first. The primary
   agent owns integration, public exports and independent review.
5. Validate affected behavior first; package tests run from their package directory.
   Broaden to `just test`, `just lint` and `just check-contracts` for integration.
   Packaging changes require real no-Gradle APK/AAB acceptance; device claims
   require device evidence.
6. Update usage docs/ADRs and dated evidence. Keep plans forward-only: extract
   completed work into evidence/history and remove completed plan items.

## Invariants

- Default Flutter Android success never comes from Gradle or `flutter build apk`.
  Preserve `flutter assemble` plus direct Android tools. No Rust hybrid revival.
- Constructors and typed contracts are the extension surface. Preserve `Oka`,
  `Target`, `Pipeline`, artifact validation and compatibility facades.
- Inspection is read-only unless explicit discovery/registration is requested.
  Diagnostics never grants cleanup authority; apply revalidates current state.
- Unknown identity is not death. Shared lifecycle policy owns verification,
  ownership and lease retention; platform adapters own ADB/CDP specifics.
- APK `resources.arsc` stays uncompressed and correctly aligned. APK and AAB
  signing differ; never assume apksigner signs bundles or remove user app data.
- Use Dart for repository automation; shell may be a thin entry point. Do not
  add Python runtime dependencies or a storage framework for simple JSON files.

## Capability map

Paths are workspace-relative; follow public exports when modules move.

| Capability | Owner |
| --- | --- |
| Composition, step contracts and artifacts | `packages/oka_core/lib/src/` |
| Cache storage, selection, registries and diagnostic contracts | `packages/oka_core/lib/src/store/` |
| Cache application workflows and default composition | `packages/oka/lib/src/cache/`; compatibility exports may remain in `src/cli/` |
| CLI parsing, terminal interaction and presentation | `packages/oka/lib/src/cli/` |
| Android compilation, dependencies, tools and packaging | `packages/oka_android/lib/src/` |
| Browser targets and profiles | `packages/oka_web/lib/src/session/` |
| Store publishing | `packages/oka_play/`, `packages/oka_huawei/` |
| Release inventory and synchronization | `tool/release/train.dart` and thin shell wrappers |

## Maintenance checks

- Preserve aliases, exit codes, schemas, source precedence and exact cleanup-plan
  selection. Prefer compatibility delegates for public moves.
- Source-contract tests follow implementation owners. Do not substitute source
  assertions for behavior evidence or weaken a gate merely to allow a move.
- Project-specific dependencies stay in the project. Shared embedding dependencies
  affect every host. Keep compile-only/runtime classification and JVM/Android
  variant precedence explicit.
- Run `steward validate skills/` for skill changes. Use the decision fixtures in
  [architecture_eval.md](references/architecture_eval.md) for behavior evaluation;
  structural validation alone does not prove skill behavior.
- Versions follow `tool/release/train.dart`; run `just check-contracts`.
  Publishing/tagging remains an explicit task.

## Docs and distribution

Architecture decisions belong in `docs/decisions/`; usage belongs in the relevant
guide. Update indexes/sidebar and AGENTS when ownership moves. Prefer links to
behavior SSOT over duplicated implementation prose.

Canonical skill: `plugin/skills/oka-maintenance`; root `skills` is its symlink.
Update an existing installed editable copy only when present and appropriate;
do not modify cached/system skills or implicitly add a global installation.

```bash
npx skills add Arenukvern/oka --skill oka-maintenance
```

Sources: [sources.md](references/sources.md).
