# Changelog

All notable changes to this package are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.9.1 <!-- x-release-please-version -->

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
