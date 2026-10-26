import 'package:meta/meta.dart';

/// Platform identity for an owned session: pid + process start instant.
///
/// Validated before any signal ([ADR-0052](https://github.com/Arenukvern/oka/blob/main/docs/decisions/0052-owned-process-sessions.mdx)).
@immutable
final class ProcessIdentityToken {
  const ProcessIdentityToken({required this.pid, required this.startTime});

  final int pid;

  /// Wall-clock start time used for liveness checks (platform-specific
  /// resolution at capture).
  final DateTime startTime;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProcessIdentityToken &&
          pid == other.pid &&
          startTime == other.startTime;

  @override
  int get hashCode => Object.hash(pid, startTime);

  @override
  String toString() => 'ProcessIdentityToken(pid: $pid, start: $startTime)';
}
