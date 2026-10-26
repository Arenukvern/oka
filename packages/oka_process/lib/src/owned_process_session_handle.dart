import 'package:meta/meta.dart';

import 'owned_process_launch_spec.dart';
import 'process_identity_token.dart';
import 'process_session_backend.dart';

/// Live owned session returned from [ProcessSessionBackend.launch].
@immutable
final class OwnedProcessSessionHandle {
  const OwnedProcessSessionHandle({
    required this.leaderIdentity,
    required this.backendKind,
    required this.launchSpec,
    this.controlSocketPath,
  });

  final ProcessIdentityToken leaderIdentity;
  final ProcessSessionBackendKind backendKind;
  final OwnedProcessLaunchSpec launchSpec;

  /// Unix socket path for the leader control channel (POSIX backends).
  final String? controlSocketPath;
}
