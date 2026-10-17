# Frequently asked questions (newcomers)

Answers here are grounded in the current repository — behavior lives in code
and tests; deeper “why” questions go to the
[Design FAQ](guides/design_faq.mdx) on the docs site.

## Who is oka for?

- **Flutter teams** tired of Gradle/AGP overhead and scattered Android config
  who want one typed, copyable build surface (`tool/oka_pipeline.dart`).
- **Release engineers** who need reproducible APK/AAB builds, signing, R8, and
  optional store publish targets (dry-run by default).
- **AI agents and automation** that need explainable plans (`oka explain`),
  probes (`oka debug step`), and structured failures — see
  [`AGENTS.md`](../AGENTS.md).

Oka is **not** a general-purpose build orchestrator (Bazel/Just/Melos) and
**not** a drop-in replacement for every Gradle plugin feature.

## What do I need installed?

| Tool | Required when |
| --- | --- |
| **Dart SDK** (3.12+) | Installing the `oka` CLI (`dart pub global activate oka`) |
| **Flutter SDK** | Building or running Flutter apps (`oka build`, `oka dev`, `oka run device`) |
| **Android SDK** | Android packaging; bootstrap with `oka get android-sdk` or point at an existing SDK |

From the repo, contributors also use **`just`** — see
[`CONTRIBUTING.md`](../CONTRIBUTING.md) and
[Build & configuration](guides/build_and_config.mdx).

Verify your machine with:

```bash
oka doctor
```

## How is oka different from `flutter build apk`?

The default success path **never** shells out to `flutter build apk` or Gradle.
Oka runs `flutter assemble` and invokes Android SDK tools directly (`aapt2`,
`javac`/`kotlinc`, `d8`, `zipalign`, `apksigner`). That invariant is enforced
by tests (see ADR-0001 in `docs/decisions/`).

Trade-off: you do **not** get full Gradle/AGP compatibility (AIDL,
RenderScript, data binding, NDK, etc.). Unsupported cases should fail loudly
rather than silently falling back.

## Where does configuration live?

Precedence (later wins):

1. `oka.yaml` or a top-level `oka:` section in `pubspec.yaml`
2. Typed Dart in `tool/oka_pipeline.dart` (discovered by convention)
3. CLI flags (`--release`, `--aab`, `--abi`, `--dart-define`, …)

`oka init` scaffolds the Dart entrypoint; `oka init --yaml` keeps a YAML-first
flow. Details: [Build & configuration guide](guides/build_and_config.mdx).

## Where do build outputs and caches go?

- **Project outputs:** `.oka_cache/build/` (APK, AAB, intermediates)
- **Shared inputs:** `~/.oka/store` and related paths under `~/.oka/`

Inspect and prune with `oka cache` and `oka cache clean` — see
[Cache storage guide](guides/cache_storage.mdx).

## Which platforms are supported today?

| Area | Status |
| --- | --- |
| **Android** (APK, AAB, dev loop, plugins) | Deepest; primary focus |
| **Web** | Configuration/distribution layer (shell station, deploy targets); compile stays `flutter build web` |
| **Store publish** (Play, Huawei, RuStore) | Separate packages composed as `oka run <target>` |
| **iOS / desktop** | Criteria-gated; not the current default path |

See [Why this repo matters](start_here/why_this_repo_matters.mdx) for expansion
gates and [Phase checklist](PHASE_CHECKLIST.mdx) for test-backed status.

## Do I still need Gradle in my repo?

**No** for the oka default build path. Many migrated apps keep Gradle files
during transition; oka does not require the Gradle daemon for `oka build`.
Migration walkthrough: [Gradle migration](guides/gradle_migration.mdx).

## How do store uploads work?

Declare publish targets in `tool/oka_pipeline.dart`. By default, `oka run
<publish-target>` is a **dry-run plan** (endpoint, track, artifact) with no
HTTP and no credentials on the wire. Credentials are **paths**, not inline
secrets. Guides: [Publishing](guides/publishing.mdx),
[Accounts & stores](guides/accounts_and_stores.mdx).

## What is `oka dev` vs `oka run device`?

- **`oka run device`** — one-shot install → launch → scan device logs for known
  failure signatures.
- **`oka dev`** — dev session with hot reload / hot restart (Dart-only; native,
  manifest, and asset changes need a rebuild). See ADR-0011 and the
  [Build guide — Dev loop](guides/build_and_config.mdx).

## What are live update / `oka ship`?

Experimental stack (`oka_dart_kernel`, `oka_update`) for patching running Dart
programs and shipping store-free updates. It is **not** published on pub.dev;
it runs from an oka repo checkout. Start with
[Live update guide](guides/live_update.mdx) and ADR-0037.

## How do I contribute or report bugs?

- **Contributing:** [Contribution guide](contributing/contribution_guide.mdx) ·
  [`CONTRIBUTING.md`](../CONTRIBUTING.md)
- **Security:** [`SECURITY.md`](../SECURITY.md) (no public issues for vulns)
- **Code of conduct:** [`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md)

Before merging, run `just check-contracts` (or the CI-equivalent gates).

## Where is the changelog?

Release history for the CLI package lives in
[`packages/oka/CHANGELOG.md`](../packages/oka/CHANGELOG.md). Versions are
managed on `main` via release-please (see contribution guide).

## More questions?

| Topic | Doc |
| --- | --- |
| Copy-paste commands | [Quick recipes](start_here/quick_recipes.mdx) |
| How to run/build/test | [Build & configuration](guides/build_and_config.mdx) |
| Design rationale | [Design FAQ](guides/design_faq.mdx) |
| Agent routing | [`AGENTS.md`](../AGENTS.md) |
