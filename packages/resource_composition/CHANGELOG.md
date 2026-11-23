# Changelog

## 0.13.0

### Minor Changes

- Raise Dart SDK floor to ^3.14.0 (Flutter 3.50 toolchain).
## 0.12.1

### Patch Changes

- **Release-train smoke cut — the first train where every published package
  has its own verified per-package pub.dev tag pattern
  (`<package>-v{{version}}`, repo `Arenukvern/oka`).**
  
  - Automated publishing verified server-side for all 17 published packages;
    `oka_service`, `oka_desktop`, `oka_google_play`, `oka_app_gallery`
    re-enabled after config drift, `oka_update` enabled for the first time.
  - No functional changes: the patch bumps exercise the OIDC publish legs
    end-to-end against the corrected tag patterns.
All notable changes to this package are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.12.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.11.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.3

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.2

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.1

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.8.1

- Part of the 0.8.1 train: usage-banner and doctor doc-pointer fixes in the
  `oka` CLI; no package-specific changes in this package.

## 0.8.0

- ArtifactFresh readiness provider: artifact-vs-sources freshness detection.

## 0.7.0

### Changed

- Release train alignment with `oka` 0.7.0 (no API changes in this package).

## 0.4.0

### Added

- Initial contracts: `Composition`/`Component` immutable graphs with
  validate-and-explain before side effects, typed readiness declarations
  (`HandshakeLine`, `FilePresent`, `LogPattern`, `TcpConnect`, `ReadinessAll`)
  with composition-declared budgets, typed `OutputRef`/`ResolvedOutputs`
  promises, lifecycle values (`ResourceScope`, `CrashPolicy`,
  `IdentityRequirement`), lifecycle events with terminal causes, bounded
  `LogTap`, the `ResourceProvider` interface with declared capabilities,
  `CompositionRunner` with reverse-order teardown that never masks the
  original failure, evidence sinks, and a scripted `FakeProvider`.


