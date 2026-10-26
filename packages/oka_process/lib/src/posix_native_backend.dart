import 'owned_process_launch_spec.dart';
import 'owned_process_session_handle.dart';
import 'process_session_backend.dart';
import 'stop_receipt.dart';

final _posixNativeUnsupported = UnsupportedError(
  'posix-native: P1 not implemented — native helper pending',
);

/// `posix-native` backend: hash-verified helper from `native/` (P1).
final class PosixNativeProcessSessionBackend implements ProcessSessionBackend {
  @override
  ProcessSessionBackendKind get kind => ProcessSessionBackendKind.posixNative;

  @override
  Future<OwnedProcessSessionHandle> launch(OwnedProcessLaunchSpec spec) =>
      Future<OwnedProcessSessionHandle>.error(_posixNativeUnsupported);

  @override
  Future<StopReceipt> stop(OwnedProcessSessionHandle handle) =>
      Future<StopReceipt>.error(_posixNativeUnsupported);
}
