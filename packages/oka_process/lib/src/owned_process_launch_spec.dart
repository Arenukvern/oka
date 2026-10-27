import 'package:meta/meta.dart';

import 'graceful_cleanup_hook.dart';
import 'observation_budget.dart';
import 'owned_session_mode.dart';

/// Declarative launch parameters for an owned POSIX session.
@immutable
final class OwnedProcessLaunchSpec {
  const OwnedProcessLaunchSpec({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.observationBudget = ObservationBudget.defaults,
    this.gracefulCleanupHook,
    this.protocol = 1,
    this.mode = OwnedSessionMode.owned,
    this.marker,
  });

  /// Admitted target executable (`--` argv).
  final String executable;

  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final ObservationBudget observationBudget;
  final GracefulCleanupHook? gracefulCleanupHook;

  /// p1 `--protocol` (only **1** is supported).
  final int protocol;

  /// p1 `--mode` (only [OwnedSessionMode.owned] for the Perl leader).
  final OwnedSessionMode mode;

  /// Launch nonce; generated when omitted.
  final String? marker;
}
