import 'dart:io';

import 'package:oka_core/oka_core.dart';

import 'freshness.dart';

/// Declares how one build artifact is kept fresh, and owns the mechanics:
/// fresh-skip → single-flight → double-check → lock-backed cooldown →
/// staged build → atomic rename (ADR-0047).
///
/// The [build] callback compiles to a **staged** path and returns it;
/// [ensureFresh] performs the rename, so a failed build always leaves the
/// last-known-good artifact in place. The cooldown is checked under the
/// lock and stamped for every trigger, so it throttles back-to-back
/// rebuilds **across processes** — the control a lane-local debounce
/// cannot provide when several owners share one artifact.
final class ArtifactRefreshSpec {
  const ArtifactRefreshSpec({
    required this.artifactPath,
    required this.lockPath,
    this.sourceRoots = const <String>[],
    this.sourceFiles = const <String>[],
    this.packageConfigPath,
    this.scanPackageConfigLibs = false,
    this.extensions = const <String>['dart'],
    this.cooldown = Duration.zero,
  });

  /// The kept-fresh artifact (last-known-good).
  final String artifactPath;

  /// Inode lock file ([InodeLock]); never deleted, kernel-released on
  /// process death. The cooldown stamp lives next to it.
  final String lockPath;

  /// Directories scanned for newer sources (see
  /// [inspectArtifactFreshness]).
  final List<String> sourceRoots;

  /// Individual files compared by mtime.
  final List<String> sourceFiles;

  /// Newer package config ⇒ stale; with [scanPackageConfigLibs], also
  /// scans every lib the config resolves.
  final String? packageConfigPath;
  final bool scanPackageConfigLibs;
  final List<String> extensions;

  /// Minimum gap between build starts, across all processes. The stamp is
  /// written when a build starts; a trigger inside the gap skips with
  /// [ArtifactRefreshResult.retryAfter].
  final Duration cooldown;

  bool isFresh() => inspectArtifactFreshness(
        artifactPath: artifactPath,
        sourceRoots: sourceRoots,
        sourceFiles: sourceFiles,
        packageConfigPath: packageConfigPath,
        scanPackageConfigLibs: scanPackageConfigLibs,
        extensions: extensions,
      ).fresh;

  /// Fresh-skip → lock → double-check → cooldown → build → rename.
  /// Never throws for expected outcomes; a throwing [build] is reported
  /// as [ArtifactRefreshOutcome.failed] with its error.
  Future<ArtifactRefreshResult> ensureFresh({
    required Future<String?> Function() build,
  }) async {
    final started = DateTime.now();
    ArtifactRefreshResult done(
      ArtifactRefreshOutcome outcome, {
      Duration? retryAfter,
      String? error,
    }) =>
        ArtifactRefreshResult(
          outcome: outcome,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          retryAfter: retryAfter,
          error: error,
        );

    if (isFresh()) return done(ArtifactRefreshOutcome.fresh);

    File(lockPath).parent.createSync(recursive: true);
    final lock = await InodeLock.tryAcquire(File(lockPath));
    if (lock == null) return done(ArtifactRefreshOutcome.inFlight);
    try {
      if (isFresh()) return done(ArtifactRefreshOutcome.freshAfterWait);

      final stamp = File('$lockPath.lastStart');
      if (cooldown > Duration.zero && stamp.existsSync()) {
        final age = DateTime.now().difference(stamp.lastModifiedSync());
        if (age < cooldown) {
          return done(
            ArtifactRefreshOutcome.cooldown,
            retryAfter: cooldown - age,
          );
        }
      }
      stamp.writeAsStringSync('${DateTime.now().millisecondsSinceEpoch}\n');

      final String? staged;
      try {
        staged = await build();
      } on Object catch (error) {
        return done(ArtifactRefreshOutcome.failed, error: '$error');
      }
      if (staged == null) {
        return done(ArtifactRefreshOutcome.failed);
      }
      final stagedFile = File(staged);
      if (!stagedFile.existsSync() || stagedFile.lengthSync() == 0) {
        return done(ArtifactRefreshOutcome.failed);
      }
      stagedFile.renameSync(artifactPath);
      return done(ArtifactRefreshOutcome.built);
    } finally {
      await lock.close();
    }
  }
}

enum ArtifactRefreshOutcome {
  /// Already fresh — nothing ran.
  fresh,

  /// A concurrent holder refreshed it while this trigger waited for the
  /// lock.
  freshAfterWait,

  /// Another process holds the build lock.
  inFlight,

  /// A build started less than [ArtifactRefreshSpec.cooldown] ago.
  cooldown,

  /// The build ran and the artifact was atomically swapped.
  built,

  /// The build failed or produced nothing; last-known-good stands.
  failed,
}

final class ArtifactRefreshResult {
  const ArtifactRefreshResult({
    required this.outcome,
    required this.durationMs,
    this.retryAfter,
    this.error,
  });

  final ArtifactRefreshOutcome outcome;
  final int durationMs;

  /// For [ArtifactRefreshOutcome.cooldown]: when a rebuild may start.
  final Duration? retryAfter;

  /// For [ArtifactRefreshOutcome.failed]: the build's error, if any.
  final String? error;

  Map<String, Object?> toJson() => {
        'outcome': outcome.name,
        'durationMs': durationMs,
        if (retryAfter != null) 'retryAfterMs': retryAfter!.inMilliseconds,
        if (error != null) 'error': error,
      };
}
