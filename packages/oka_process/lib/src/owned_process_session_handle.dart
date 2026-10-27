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
    required this.runtimeKey,
    this.controlSocketPath,
    this.marker,
    this.sessionId,
  });

  final ProcessIdentityToken leaderIdentity;
  final ProcessSessionBackendKind backendKind;
  final OwnedProcessLaunchSpec launchSpec;

  /// Unix socket path for the leader control channel (POSIX backends).
  final String? controlSocketPath;

  /// p1 marker (duplicated on [leaderIdentity] for convenience).
  final String? marker;

  /// p1 session id from ready line (duplicated on [leaderIdentity]).
  final int? sessionId;

  /// Opaque key for backend runtime state (not part of wire contract).
  final String runtimeKey;
}
