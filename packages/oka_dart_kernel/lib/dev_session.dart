/// The `oka dev` session (ADR-0037 §6d).
///
/// `oka` calls [runRunDevCli] directly. The kernel-graph barrel stays in
/// `oka_dart_kernel.dart`; this library is the dev-session entry.
library;

export 'src/dev/run_dev.dart';
