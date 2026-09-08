/// `--watch` change classification & automatic dispatch (ADR-0011 H4).
///
/// Honest routing (ADR-0011 §5): hot reload is **Dart-only**. Native,
/// resource, manifest, config, and dependency changes always mean a full
/// `oka build apk --debug` + reinstall — reload is never suggested for
/// them ([fullRebuildMessage] in `dev_session.dart` carries the exact
/// command).
///
/// Pieces:
///
/// * [classifyChanges] — pure table-driven classification over changed
///   paths ([ChangeAction.hotReload] / [ChangeAction.fullRebuild] /
///   [ChangeAction.ignore], with per-path reasons).
/// * [debounceStream] — quiet-period debounce over a merged change stream
///   (a save storm is one dispatch).
/// * [computeDevWatchPaths] / [watchDevPaths] — the watched surface:
///   `lib/`, the target file, `android/`, `assets/`, `oka.yaml`,
///   `pubspec.yaml` (via the `watcher` package, direct dependency per the
///   H4 checklist).
/// * [watchCommandStream] — classification → [DevControlCommand]s for the
///   [DevSession] control loop: Dart → reload; native → `rebuildRouting`
///   (with `--rebuild-on-native`) or the printed rebuild message.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import 'dev_session.dart';

/// What to do with a set of changed paths.
enum ChangeAction {
  /// Dart-only change — safe for `app.reload`.
  hotReload,

  /// Native/res/manifest/config/dependency change — full rebuild required.
  fullRebuild,

  /// Not relevant to the running app (build outputs, tests, tooling).
  ignore,
}

/// Pure classification result: [action] plus human-readable [reasons]
/// (`path → why`), so an agent can see exactly why a rebuild was routed.
class ChangeClassification {
  const ChangeClassification({required this.action, required this.reasons});

  final ChangeAction action;

  /// Per-path reasons, e.g. `lib/main.dart → Dart (reload)`.
  final List<String> reasons;
}

/// Directory segments that never affect the running app.
const _ignoredDirSegments = <String>{
  '.oka_cache',
  '.dart_tool',
  '.git',
  'build',
  '.idea',
};

/// Root-level file names whose change requires a full rebuild
/// (configuration/dependencies feed the kernel and packaging).
const _rebuildRootFiles = <String>{'oka.yaml', 'pubspec.yaml', 'pubspec.lock'};

/// Classifies changed paths (relative to the project root; absolute paths
/// are normalized). The **strongest** action wins: any rebuild-class path
/// routes the whole batch to a full rebuild.
///
/// Table-driven rules (tested against file-event fixtures):
///
/// | path | action | why |
/// |---|---|---|
/// | `lib/**.dart` | reload | Dart-only |
/// | non-Dart under `lib/` | rebuild | bundled asset (rootBundle) |
/// | `test/**.dart`, `tool/**`, `bin/**` | ignore | not in the running app |
/// | `android/**`, `*.xml`, `*.gradle`, `.kt`, `.java`, `.so`, `.aar` | rebuild | native/res/manifest |
/// | `assets/**` | rebuild | asset payload |
/// | `oka.yaml`, `pubspec.yaml/lock` | rebuild | config/deps |
/// | `.oka_cache/**`, `.dart_tool/**`, `build/**`, dot files | ignore | build/meta |
ChangeClassification classifyChanges(final Iterable<String> paths) {
  var action = ChangeAction.ignore;
  final reasons = <String>[];
  for (final raw in paths) {
    final path = p.normalize(raw).replaceAll(r'\', '/');
    final segments = path.split('/');
    final name = segments.last;
    final isDart = p.extension(name).toLowerCase() == '.dart';

    String? reason;
    if (segments.any(_ignoredDirSegments.contains) || name.startsWith('.')) {
      reason = 'ignored (build/meta)';
    } else if (segments.contains('lib')) {
      reason = isDart ? 'Dart (reload)' : 'bundled asset (full rebuild)';
    } else if (segments.contains('test') ||
        segments.contains('tool') ||
        segments.contains('bin')) {
      reason = 'ignored (tests/tooling do not affect the running app)';
    } else if (segments.contains('android') ||
        segments.contains('assets') ||
        _rebuildRootFiles.contains(name) ||
        const {
          '.xml',
          '.gradle',
          '.kt',
          '.java',
          '.so',
          '.aar',
          '.pro',
        }.contains(p.extension(name).toLowerCase())) {
      reason = 'native/res/config (full rebuild)';
    } else {
      reason = 'ignored (not part of the app surface)';
    }

    if (reason.contains('full rebuild')) {
      action = ChangeAction.fullRebuild;
    } else if (action == ChangeAction.ignore && reason == 'Dart (reload)') {
      action = ChangeAction.hotReload;
    }
    reasons.add('$path → $reason');
  }
  return ChangeClassification(action: action, reasons: reasons);
}

/// Quiet-period debounce: emits a batched list of values only after
/// [interval] passed with no new value. Values arriving during the quiet
/// window accumulate (a save storm is one dispatch).
Stream<List<T>> debounceStream<T>(
  final Stream<T> source,
  final Duration interval,
) {
  late final StreamController<List<T>> out;
  Timer? timer;
  final batch = <T>[];
  StreamSubscription<T>? sub;
  out = StreamController<List<T>>(
    onListen: () {
      sub = source.listen(
        (final v) {
          batch.add(v);
          timer?.cancel();
          timer = Timer(interval, () {
            if (batch.isEmpty || out.isClosed) return;
            out.add(List.of(batch));
            batch.clear();
          });
        },
        onDone: () {
          timer?.cancel();
          if (batch.isNotEmpty && !out.isClosed) out.add(List.of(batch));
          unawaited(out.close());
        },
      );
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () async {
      timer?.cancel();
      await sub?.cancel();
    },
  );
  return out.stream;
}

/// Merges many single-value streams into one (tiny [StreamGroup] — no
/// extra dependency).
Stream<T> mergeStreams<T>(final Iterable<Stream<T>> streams) {
  late final StreamController<T> out;
  final pendingDone = <Stream<void>>{};
  out = StreamController<T>(
    onListen: () {
      for (final s in streams) {
        pendingDone.add(s);
        s.listen(
          out.add,
          onError: out.addError,
          onDone: () {
            pendingDone.remove(s);
            if (pendingDone.isEmpty && !out.isClosed) unawaited(out.close());
          },
        );
      }
    },
    onCancel: () {
      pendingDone.clear();
    },
  );
  return out.stream;
}

/// The watched surface for a dev session (absolute paths): `lib/`, the
/// target file, `android/`, `assets/`, `oka.yaml`, `pubspec.yaml`.
/// Missing paths are skipped (a pure-Dart project may have no `android/`).
List<String> computeDevWatchPaths({
  required final String projectPath,
  final String? targetFile,
}) {
  final candidates = <String>[
    p.join(projectPath, 'lib'),
    p.join(projectPath, 'android'),
    p.join(projectPath, 'assets'),
    p.join(projectPath, 'oka.yaml'),
    p.join(projectPath, 'pubspec.yaml'),
  ];
  final resolvedTarget = (targetFile == null || targetFile.isEmpty)
      ? null
      : (p.isAbsolute(targetFile)
            ? targetFile
            : p.join(projectPath, targetFile));
  if (resolvedTarget != null) {
    // Skip the target when a watched root already covers it (e.g.
    // lib/main.dart under the lib/ watcher).
    final covered = candidates.any(
      (final c) => _isDir(c) && p.isWithin(c, resolvedTarget),
    );
    if (!covered) candidates.add(resolvedTarget);
  }
  return [
    for (final c in candidates)
      if (_exists(c)) c,
  ];
}

bool _exists(final String path) =>
    File(path).existsSync() || Directory(path).existsSync();

bool _isDir(final String path) => Directory(path).existsSync();

/// Watches the dev surface and yields debounced batches of changed paths,
/// relative to [projectPath] when inside it.
Stream<List<String>> watchDevPaths({
  required final String projectPath,
  final String? targetFile,
  final Duration debounce = const Duration(milliseconds: 300),
}) {
  final roots = computeDevWatchPaths(
    projectPath: projectPath,
    targetFile: targetFile,
  );
  final merged = mergeStreams<String>([
    for (final root in roots)
      (File(root).existsSync() ? FileWatcher(root) : DirectoryWatcher(root))
          .events
          .map((final e) => p.normalize(e.path)),
  ]);
  return debounceStream(merged, debounce).map(
    (final batch) => [
      for (final path in batch)
        if (p.isWithin(projectPath, path))
          p.relative(path, from: projectPath)
        else
          path,
    ],
  );
}

/// Classification → session commands: Dart-only batches dispatch one
/// reload; rebuild-class batches dispatch [DevControlCommand
/// .rebuildRouting] (the session prints the exact command, or — with
/// `--rebuild-on-native` — ends the session so the flow can rebuild).
/// Ignore-class batches emit nothing. [onEvent] observes every batch
/// (`--json` visibility and tests).
Stream<DevControlCommand> watchCommandStream({
  required final Stream<List<String>> changes,
  final void Function(ChangeClassification)? onEvent,
}) => changes
    .map((final batch) {
      final c = classifyChanges(batch);
      onEvent?.call(c);
      return switch (c.action) {
        ChangeAction.hotReload => DevControlCommand.reload,
        ChangeAction.fullRebuild => DevControlCommand.rebuildRouting,
        ChangeAction.ignore => null,
      };
    })
    .where((final c) => c != null)
    .cast<DevControlCommand>();
