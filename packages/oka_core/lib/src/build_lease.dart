import 'dart:convert';
import 'dart:io';

/// A machine-level lease around `flutter`/`dart` builds.
///
/// The flutter tool serializes builds through a lock, but a SECOND
/// builder does not wait politely — it fails the first build mid-flight
/// or dies on the held lock with an opaque error (measured 2026-10-02:
/// two sessions building one workspace killed each other's web builds;
/// the loser surfaced as "Error: Failed to compile application" with no
/// cause). The lease makes the contention loud and queued instead.
///
/// Two lock files: a GLOBAL one (`~/.oka/build.lock`) — the flutter
/// tool's cache lock is machine-wide, so cross-project builds collide
/// too — and a per-project one under `.dart_tool/`. Each records its
/// holder (pid + command + start time); a holder whose pid is dead is
/// STALE and taken over with a warning, never waited on.
///
/// Wire into `oka build` (the pipeline entry) and, for raw commands, the
/// shell guard — the env-level option is documented in ADR-0033.
///
/// ```dart
/// await withBuildLease('oka build web', () => runFlutterBuild(...));
/// ```
final class BuildLease {
  BuildLease._(this._globalPath, this._projectPath);

  final String _globalPath;
  final String? _projectPath;
  bool _held = false;

  /// Acquires the global (+ optional per-project) lease and runs [body],
  /// releasing on every path.
  static Future<T> withLease<T>(
    String command,
    Future<T> Function() body, {
    String? projectDir,
    bool wait = true,
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    final lease = await acquire(
      command,
      projectDir: projectDir,
      wait: wait,
      pollInterval: pollInterval,
    );
    try {
      return await body();
    } finally {
      await lease.release();
    }
  }

  /// Acquires the lease; [wait] false throws [BuildLeaseHeldException]
  /// when a live holder exists.
  static Future<BuildLease> acquire(
    String command, {
    String? projectDir,
    bool wait = true,
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    final globalPath =
        '${_home()}/.oka/build.lock';
    final projectPath =
        projectDir == null ? null : '$projectDir/.dart_tool/oka_build.lock';
    final token = <String, Object?>{
      'pid': pidOf(),
      'command': command,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
    };
    while (true) {
      final heldBy = _tryLock(globalPath, token) &&
          (projectPath == null || _tryLock(projectPath, token));
      if (heldBy) {
        final lease = BuildLease._(globalPath, projectPath)
          .._held = true;
        return lease;
      }
      if (!wait) {
        throw BuildLeaseHeldException(_currentHolder(globalPath, projectPath));
      }
      final holder = _currentHolder(globalPath, projectPath);
      // ignore: avoid_print
      print(
        'oka build lease: waiting for ${holder ?? 'another builder'} '
        '(flutter tool locks are machine-wide; builds queue here instead '
        'of failing each other)',
      );
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Releases both lock files (only the files this lease wrote).
  Future<void> release() async {
    if (!_held) return;
    _held = false;
    _unlock(_globalPath);
    final projectPath = _projectPath;
    if (projectPath != null) _unlock(projectPath);
  }

  static bool _tryLock(String path, Map<String, Object?> token) {
    final file = File(path);
    if (file.existsSync()) {
      final holder = _readHolder(file);
      if (holder != null && _pidAlive(holder['pid'] as int?)) {
        return false; // Live holder — not stale, not ours.
      }
      // Stale (dead pid) or unparseable: take over, loudly.
      // ignore: avoid_print
      print('oka build lease: taking over stale lock $path (holder: $holder)');
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(token));
    return true;
  }

  static void _unlock(String path) {
    final file = File(path);
    if (!file.existsSync()) return;
    try {
      final holder = _readHolder(file);
      // Only remove OUR file — a holder that raced us keeps its own.
      if (holder?['pid'] == pidOf()) file.deleteSync();
    } on FileSystemException {
      // Best-effort release; stale takeover covers leftovers.
    }
  }

  static Map<String, Object?>? _readHolder(File file) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  static String? _currentHolder(String globalPath, String? projectPath) {
    for (final path in [globalPath, ?projectPath]) {
      final holder = _readHolder(File(path));
      if (holder != null && _pidAlive(holder['pid'] as int?)) {
        return '${holder['command']} (pid ${holder['pid']}, since '
            '${holder['startedAt']})';
      }
    }
    return null;
  }

  static bool _pidAlive(int? pid) {
    if (pid == null || pid <= 0) return false;
    final thisPid = pidOf();
    if (pid == thisPid) return true;
    try {
      return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
    } on ProcessException {
      // Non-posix (Windows): assume alive — waiting beats clobbering.
      return true;
    }
  }

  /// Test seam: when set, replaces HOME for the global lock path.
  static String? homeOverride;

  static String _home() {
    final home = homeOverride ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME is not set; the global build lease needs it');
    }
    return home;
  }
}

/// `acquire(wait: false)` refused — a live holder owns the lease.
final class BuildLeaseHeldException implements Exception {
  BuildLeaseHeldException(this.holder);
  final String? holder;

  @override
  String toString() =>
      'build lease held by ${holder ?? 'another builder'} '
      '(wait: false refuses; the default queues)';
}

/// This process's pid (dart:io ), behind a function so tests can
/// stub the identity when simulating live/stale holders.
int pidOf() => pid;

/// Runs [body] under the build lease — the one-call guard for build
/// entry points.
Future<T> withBuildLease<T>(
  String command,
  Future<T> Function() body, {
  String? projectDir,
  bool wait = true,
}) =>
    BuildLease.withLease(command, body, projectDir: projectDir, wait: wait);
