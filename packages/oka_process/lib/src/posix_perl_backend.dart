import 'owned_process_launch_spec.dart';
import 'owned_process_session_handle.dart';
import 'process_session_backend.dart';
import 'stop_receipt.dart';

final _posixPerlUnsupported = UnsupportedError(
  'posix-perl: P0 not implemented — pending dfp contract + PR #5',
);

/// Reference `posix-perl` leader (P0). Implementation follows dfp contract.
final class PosixPerlProcessSessionBackend implements ProcessSessionBackend {
  @override
  ProcessSessionBackendKind get kind => ProcessSessionBackendKind.posixPerl;

  @override
  Future<OwnedProcessSessionHandle> launch(OwnedProcessLaunchSpec spec) =>
      Future<OwnedProcessSessionHandle>.error(_posixPerlUnsupported);

  @override
  Future<StopReceipt> stop(OwnedProcessSessionHandle handle) =>
      Future<StopReceipt>.error(_posixPerlUnsupported);
}
