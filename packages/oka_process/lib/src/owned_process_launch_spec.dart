import 'package:meta/meta.dart';

import 'graceful_cleanup_hook.dart';
import 'observation_budget.dart';

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
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final ObservationBudget observationBudget;
  final GracefulCleanupHook? gracefulCleanupHook;
}
