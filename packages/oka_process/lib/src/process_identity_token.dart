import 'package:meta/meta.dart';

/// Platform identity for an owned session: pid, start instant, p1 marker, sid.
///
/// Validated before any signal ([ADR-0052](https://github.com/Arenukvern/oka/blob/main/docs/decisions/0052-owned-process-sessions.mdx)).
@immutable
final class ProcessIdentityToken {
  const ProcessIdentityToken({
    required this.pid,
    required this.startTime,
    required this.marker,
    required this.sessionId,
  });

  final int pid;

  /// Wall-clock start time used for liveness checks (platform-specific
  /// resolution at capture).
  final DateTime startTime;

  /// p1 control + stderr authentication nonce.
  final String marker;

  /// Session id from the leader ready line (`setsid()`).
  final int sessionId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProcessIdentityToken &&
          pid == other.pid &&
          startTime == other.startTime &&
          marker == other.marker &&
          sessionId == other.sessionId;

  @override
  int get hashCode => Object.hash(pid, startTime, marker, sessionId);

  @override
  String toString() =>
      'ProcessIdentityToken(pid: $pid, sid: $sessionId, marker: $marker)';
}
