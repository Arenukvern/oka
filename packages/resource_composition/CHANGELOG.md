# Changelog

All notable changes to this package are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
