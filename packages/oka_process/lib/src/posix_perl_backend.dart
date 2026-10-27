import 'owned_process_launch_spec.dart';
import 'owned_process_session_handle.dart';
import 'posix_perl_session_runtime.dart';
import 'process_session_backend.dart';
import 'stop_receipt.dart';

/// Reference `posix-perl` leader (p1 contract).
final class PosixPerlProcessSessionBackend implements ProcessSessionBackend {
  @override
  ProcessSessionBackendKind get kind => ProcessSessionBackendKind.posixPerl;

  @override
  Future<OwnedProcessSessionHandle> launch(OwnedProcessLaunchSpec spec) =>
      launchPosixPerlSession(spec);

  @override
  Future<StopReceipt> stop(OwnedProcessSessionHandle handle) =>
      stopPosixPerlSession(handle);
}
