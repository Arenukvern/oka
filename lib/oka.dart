/// Oka: no-Gradle build system for Flutter Android (ADR-0006 package layout).
///
/// - `oka_core` — contracts: typed context, [BuildStep]/[Artifact], `Oka` root
/// - `oka_android` — Android pipelines, steps, toolchain, specs
/// - this package — the `oka` CLI (bin/), doctor/get commands
///
/// Hook authors should depend on `oka_android` (which transitively provides
/// `oka_core`), not this CLI package, to keep host-app dependency surface
/// minimal.
library;

export 'package:oka_android/oka_android.dart';
export 'package:oka_core/oka_core.dart';

export 'src/version.dart';
