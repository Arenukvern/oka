/// Declarative command lanes for the live watcher (ADR-0038).
///
/// A lane turns file-system events under declared roots into serialized,
/// debounced command runs. The runner is mechanics only: it emits receipts
/// and never retries, never interprets output, never gates. Correctness —
/// analyze/test gates, atomic swaps, last-known-good — is the command's
/// declared promise (ADR-0036: orchestration in Dart, policy in the
/// command).
library;

import 'dart:async';
import 'dart:io';

/// One declared lane from the spec's optional `commands` section.
final class CommandLaneSpec {
  const CommandLaneSpec({
    required this.name,
    required this.watch,
    required this.run,
    this.project,
    this.extensions = const [],
    this.debounceMs = 500,
  });

  /// Parses and validates one spec entry. Throws [ArgumentError] with a
  /// lane-named message so a bad spec fails loudly at boot, not at the
  /// first save.
  factory CommandLaneSpec.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw ArgumentError('command lane needs a non-empty "name"');
    }
    final watch = json['watch'];
    if (watch is! List ||
        watch.isEmpty ||
        watch.any((final root) => root is! String)) {
      throw ArgumentError('command lane "$name" needs non-empty string '
          '"watch" roots');
    }
    final run = json['run'];
    if (run is! List ||
        run.isEmpty ||
        run.any((final arg) => arg is! String)) {
      throw ArgumentError('command lane "$name" needs a non-empty string '
          '"run" argv (no shell)');
    }
    final project = json['project'];
    final extensions = json['extensions'];
    final debounceMs = json['debounceMs'];
    return CommandLaneSpec(
      name: name,
      watch: List<String>.from(watch),
      run: List<String>.from(run),
      project: project is String && project.isNotEmpty ? project : null,
      extensions:
          extensions is List ? List<String>.from(extensions) : const [],
      debounceMs: debounceMs is int && debounceMs >= 0 ? debounceMs : 500,
    );
  }

  /// Unique lane label, echoed in every receipt.
  final String name;

  /// Roots watched recursively; events under any of them trigger a run.
  final List<String> watch;

  /// Command argv executed with no shell; stdio is inherited.
  final List<String> run;

  /// Working directory for the command; defaults to the watcher's project
  /// root (then the current directory).
  final String? project;

  /// Path suffixes that trigger a run; empty means any file event.
  final List<String> extensions;

  /// Quiet period after the last event before the run starts.
  final int debounceMs;
}

/// The running form of one [CommandLaneSpec].
final class CommandLane {
  CommandLane({
    required this.spec,
    this.projectRoot,
    void Function(Map<String, Object?> receipt)? onReceipt,
  }) : _onReceipt =
           onReceipt ?? ((final receipt) => throw UnimplementedError());

  final CommandLaneSpec spec;

  /// Fallback working directory when the spec declares no [CommandLaneSpec.project].
  final String? projectRoot;
  final void Function(Map<String, Object?> receipt) _onReceipt;

  final List<StreamSubscription<FileSystemEvent>> _subscriptions = [];
  Timer? _debounce;
  Future<void> _inFlight = Future.value();
  bool _pending = false;

  /// Whether [path] passes the lane's extension filter.
  bool matches(String path) {
    if (spec.extensions.isEmpty) return true;
    return spec.extensions.any(path.endsWith);
  }

  /// Subscribes to the watch roots. Throws when a root does not exist —
  /// a lane that cannot watch must fail loudly, not silently never run.
  void start() {
    for (final dir in spec.watch) {
      _subscriptions.add(
        Directory(dir).watch(recursive: true).listen(
              _onEvent,
              onError: (Object error) {
                _onReceipt({
                  'event': 'command_error',
                  'lane': spec.name,
                  'watch': dir,
                  'error': '$error',
                });
              },
            ),
      );
    }
  }

  Future<void> stop() async {
    _debounce?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _inFlight;
  }

  void _onEvent(FileSystemEvent event) {
    if (event is FileSystemModifyEvent && !event.contentChanged) return;
    if (!matches(event.path)) return;
    _pending = true;
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: spec.debounceMs), _fireDue);
  }

  void _fireDue() {
    if (!_pending) return;
    _pending = false;
    // Runs serialize per lane; a burst during a run collapses into the
    // one already-pending follow-up, never a queue and never a storm.
    _inFlight = _inFlight.then((_) => _runOnce());
  }

  Future<void> _runOnce() async {
    final started = DateTime.now();
    _onReceipt({'event': 'command_start', 'lane': spec.name});
    int exitCode;
    try {
      final process = await Process.start(
        spec.run.first,
        spec.run.sublist(1),
        workingDirectory: spec.project ?? projectRoot ?? Directory.current.path,
        mode: ProcessStartMode.inheritStdio,
      );
      exitCode = await process.exitCode;
    } on Object catch (error) {
      _onReceipt({
        'event': 'command_receipt',
        'lane': spec.name,
        'ok': false,
        'exitCode': -1,
        'durationMs': DateTime.now().difference(started).inMilliseconds,
        'error': '$error',
      });
      return;
    }
    _onReceipt({
      'event': 'command_receipt',
      'lane': spec.name,
      'ok': exitCode == 0,
      'exitCode': exitCode,
      'durationMs': DateTime.now().difference(started).inMilliseconds,
    });
  }
}
