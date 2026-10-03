/// The invisible loop (ADR-0035): watch the declared unit files; when the
/// user saves one, compile its library as a unit delta and apply it to the
/// connected targets — before they alt-tab back. Success is silent; the
/// receipt stream exists for programs and for the moments something must
/// be said (refusals, probe failures, unknown state).
library;

import 'dart:async';
import 'dart:io';

import 'events.dart';
import 'receipt.dart';
import 'session.dart';
import 'spec.dart';
import 'target.dart';

/// Watches the files of one declared unit and live-patches every connected
/// target on each save.
///
/// ```dart
/// final watcher = LiveWatcher(
///   unit: 'feature',
///   files: ['$appRoot/lib/units/feature.dart'],
///   revision: 'dev',
///   targets: [const TargetSpec.vmPort(8242)],
///   probes: [/* expect + hold */],
///   root: appRoot,
///   compile: pipelineDeltaCompiler(toolchain),
/// );
/// unawaited(watcher.start());
/// ```
class LiveWatcher {
  LiveWatcher({
    required this.unit,
    required this.files,
    required this.revision,
    required this.targets,
    required this.probes,
    required this.compile,
    required this.root,
    this.onEvent,
    this.targetOverrides = const {},
    this.debounce = const Duration(milliseconds: 400),
  });

  final String unit;
  final List<String> files;
  final String revision;
  final List<TargetSpec> targets;
  final List<ProbeSpec> probes;
  final UnitDeltaCompiler compile;
  final String root;

  /// Called for every event; success is already silent — [onEvent] exists
  /// for compositions that want the ladder (or logs).
  final void Function(LivePatchEvent event)? onEvent;

  /// Test/injection seam: replace a spec-built target with a custom one.
  final Map<String, LivePatchTarget> targetOverrides;
  final Duration debounce;

  final _receipts = StreamController<LivePatchReceipt>.broadcast();
  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _debounce;
  String? _lastPath;
  Future<void> _inFlight = Future.value();
  var _stopped = false;

  /// Receipts, one per applied change (successes included — but nothing
  /// consumes them unless the composition wants to).
  Stream<LivePatchReceipt> get receipts => _receipts.stream;

  /// Starts watching. Returns when the watchers are set up.
  void start() {
    final watched = files.map((f) => File(f).absolute.path).toSet();
    final dirs = files.map((f) => File(f).absolute.parent).toSet();
    for (final dir in dirs) {
      _watchSub = dir.watch().listen((event) {
        if (_stopped) return;
        if (!watched.contains(File(event.path).absolute.path)) return;
        if (event is FileSystemModifyEvent && !event.contentChanged) return;
        _schedule(event.path);
      });
    }
  }

  void _schedule(String path) {
    _lastPath = path;
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      final file = _lastPath;
      _lastPath = null;
      if (file == null || _stopped) return;
      // Coalesce: while one apply runs, later saves collapse into the next
      // run — the program is patched to its LATEST state, never stale.
      _inFlight = _inFlight.then((_) => _apply(file));
    });
  }

  Future<void> _apply(String file) async {
    if (_stopped) return;
    final receipt = await applyChange(
      LivePatchSpec(
        revision: revision,
        unit: unit,
        patches: const [],
        targets: targets,
        probes: probes,
      ),
      changedFile: file,
      compile: compile,
      root: root,
      onEvent: onEvent,
      targetOverrides: targetOverrides,
    );
    if (!_receipts.isClosed) _receipts.add(receipt);
  }

  Future<void> stop() async {
    _stopped = true;
    _debounce?.cancel();
    await _watchSub?.cancel();
    await _inFlight;
    await _receipts.close();
  }
}
