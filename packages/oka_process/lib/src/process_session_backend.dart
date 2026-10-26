import 'owned_process_launch_spec.dart';
import 'owned_process_session_handle.dart';
import 'stop_receipt.dart';

/// Backend selector for owned POSIX sessions (ADR-0052).
enum ProcessSessionBackendKind {
  posixPerl('posix-perl'),
  posixNative('posix-native');

  const ProcessSessionBackendKind(this.wireName);

  final String wireName;
}

/// Launch and stop owned process groups on Linux/macOS.
abstract interface class ProcessSessionBackend {
  ProcessSessionBackendKind get kind;

  Future<OwnedProcessSessionHandle> launch(OwnedProcessLaunchSpec spec);

  Future<StopReceipt> stop(OwnedProcessSessionHandle handle);
}
