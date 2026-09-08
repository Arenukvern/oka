import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Fingerprint-based step cache (ADR-0006: incremental builds).
///
/// Persists per-step input fingerprints + output references into
/// `<buildDir>/step_cache.json`. A step skips re-execution only when its
/// fingerprint matches AND its recorded outputs still exist. Any mismatch —
/// sources, dependencies, defines, tool versions — forces a full re-run.
/// Deleting the build dir (or `oka clean`) resets everything.
class StepCache {

  StepCache(this.buildDir, {this.verbose = false});
  final String buildDir;
  final bool verbose;

  File get _file => File(p.join(buildDir, 'step_cache.json'));

  Map<String, dynamic> _data = {};

  Future<void> load() async {
    final f = _file;
    if (await f.exists()) {
      try {
        _data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      } on FormatException {
        _data = {};
      }
    }
  }

  /// Returns persisted output map when [fingerprint] matches, all
  /// [requiredOutputs] (file paths) still exist, and [validate] passes
  /// (used for list-valued outputs such as dex file lists); null otherwise.
  Map<String, dynamic>? hit(
    final String step,
    final String fingerprint, {
    final List<String> requiredOutputs = const [],
    final bool Function(Map<String, dynamic> outputs)? validate,
  }) {
    final entry = _data[step] as Map<String, dynamic>?;
    if (entry == null) {
      if (verbose) print('   cache miss ($step): no entry');
      return null;
    }
    if (entry['fingerprint'] != fingerprint) {
      if (verbose) print('   cache miss ($step): inputs changed');
      return null;
    }
    for (final out in requiredOutputs) {
      if (!File(out).existsSync() && !Directory(out).existsSync()) {
        if (verbose) print('   cache miss ($step): output missing: $out');
        return null;
      }
    }
    if (validate != null && !validate(entry)) {
      if (verbose) print('   cache miss ($step): outputs incomplete');
      return null;
    }
    if (verbose) print('   cache hit ($step) — skipping');
    return entry;
  }

  Future<void> store(
    final String step,
    final String fingerprint,
    final Map<String, dynamic> outputs,
  ) async {
    _data[step] = {'fingerprint': fingerprint, ...outputs};
    final f = _file;
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(_data), flush: true);
  }

  /// Drops a step's entry (e.g. after a failed downstream step that may have
  /// consumed its outputs).
  Future<void> invalidate(final String step) async {
    _data.remove(step);
    final f = _file;
    if (await f.exists()) {
      await f.writeAsString(jsonEncode(_data), flush: true);
    }
  }
}

/// Stable hash over a list of input files (path + size + mtime) plus scalar
/// extras (mode, defines, tool versions, …). Missing files hash as misses —
/// never silently reuse.
Future<String> fingerprintInputs(
  final Iterable<String> paths, {
  final Iterable<String> extras = const [],
}) async {
  final sink = _HashSink();
  for (final extra in extras) {
    sink.add('extra:$extra\n');
  }
  final sorted = paths.toList()..sort();
  for (final path in sorted) {
    final f = File(path);
    if (!f.existsSync()) {
      sink.add('missing:$path\n');
      continue;
    }
    final stat = f.statSync();
    if (stat.size <= 1048576) {
      // Small files (sources, manifests, res): hash CONTENT — regenerated
      // files keep stable fingerprints when their bytes are unchanged.
      final digest = sha256.convert(await f.readAsBytes()).toString();
      sink.add('content:$path:$digest\n');
    } else {
      // Large artifacts (jars, AARs): size + mtime is stable and cheap.
      sink.add('file:$path:${stat.size}:${stat.modified.millisecondsSinceEpoch}\n');
    }
  }
  return sink.digest;
}

class _HashSink {
  final _output = _StringSink();
  void add(final String s) => _output.write(s);
  String get digest => sha256.convert(utf8.encode(_output.toString())).toString();
}

class _StringSink {
  final _sb = StringBuffer();
  void write(final String s) => _sb.write(s);
  @override
  String toString() => _sb.toString();
}

/// Collects all files under [dir] (recursively), or returns empty when the
/// dir does not exist.
List<String> filesUnder(final String dir, {final String? extension}) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  final out = <String>[];
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is File) {
      if (extension != null && !e.path.endsWith(extension)) continue;
      out.add(e.path);
    }
  }
  return out;
}
