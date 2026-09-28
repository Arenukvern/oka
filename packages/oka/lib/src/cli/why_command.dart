import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;

/// `oka why <step>` (ADR-0029 D4): explain a step cache entry — which
/// inputs it fingerprinted, which of them changed since the cached run, and
/// which build-affecting inputs were *not* covered (the gap that hid the
/// 2026-09-27 stale-AOT bug).
///
/// Read-only: recomputes per-file digests and diffs them against the
/// digests recorded at cache time. Steps record input digests from oka
/// 0.6.0; older caches report "no recorded inputs — rebuild once".
class WhyCommand {
  Future<void> run(final List<String> args) async {
    var mode = 'release';
    var project = Directory.current.path;
    String? step;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--mode') {
        mode = args[++i];
      } else if (a.startsWith('--mode=')) {
        mode = a.substring('--mode='.length);
      } else if (a == '--project') {
        project = args[++i];
      } else if (a.startsWith('--project=')) {
        project = a.substring('--project='.length);
      } else if (a == '-h' || a == '--help') {
        print('Usage: oka why <step> [--mode release] [--project <dir>]');
        print('');
        print('Steps recording input digests: flutter-assemble, release-aot.');
        return;
      } else if (!a.startsWith('-') && step == null) {
        step = a;
      }
    }
    if (step == null || step.isEmpty) {
      stderr.writeln(
        'oka why: a step name is required — e.g. `oka why release-aot`',
      );
      exit(64);
    }

    final cacheFile = File(
      p.join(project, '.oka_cache', 'build', mode, 'step_cache.json'),
    );
    if (!cacheFile.existsSync()) {
      stderr.writeln(
        'oka why: no step cache at ${p.relative(cacheFile.path)} — '
        'run `oka build` first',
      );
      exit(66);
    }
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException {
      stderr.writeln('oka why: step cache is corrupt — run `oka clean`');
      exit(65);
    }
    final entry = data[step] as Map<String, dynamic>?;
    if (entry == null) {
      stderr.writeln(
        'oka why: no cache entry for "$step" (have: '
        '${data.keys.toList()..sort()})',
      );
      exit(66);
    }

    print('🔎 $step (mode: $mode)');
    print('   cache: ${p.relative(cacheFile.path)}');
    final digests = (entry['input_digests'] as Map<String, dynamic>? ?? {})
        .cast<String, String>();
    if (digests.isEmpty) {
      print(
        '   ℹ️  no recorded input digests (built before oka 0.6.0) — '
        'rebuild once to record them',
      );
      return;
    }

    var changed = 0;
    var missing = 0;
    final unchanged = <String>[];
    for (final entry in digests.entries) {
      final f = File(entry.key);
      if (!f.existsSync()) {
        // ignore: avoid_print
        print('   🗑️  missing:   ${_rel(entry.key, project)}');
        missing++;
        continue;
      }
      final current = await fingerprintInputsDetailed(
        [entry.key],
      ).then((final r) => r.fileDigests[entry.key]!);
      if (current != entry.value) {
        // ignore: avoid_print
        print('   ✏️  changed:   ${_rel(entry.key, project)}');
        changed++;
      } else {
        unchanged.add(entry.key);
      }
    }
    print(
      '   inputs: ${digests.length} '
      '($changed changed, $missing missing, '
      '${unchanged.length} unchanged)',
    );
    if (changed == 0 && missing == 0) {
      print('   ✅ cache is fresh — the step would reuse its outputs');
    }

    // Coverage check for the kernel/AOT steps: inputs that participate in
    // the build but were never fingerprinted (the 2026-09-27 stale-AOT
    // bug class).
    if (step == 'flutter-assemble' || step == 'release-aot') {
      final covered = digests.keys.toSet();
      final expected = <String>[
        ...filesUnder(p.join(project, 'lib'), extension: '.dart'),
        ...filesUnder(p.join(project, 'packages'), extension: '.dart'),
        ...pathDependencyInputs(project),
      ];
      final uncovered = expected.where((final f) => !covered.contains(f));
      var shown = 0;
      for (final f in uncovered) {
        if (shown == 0) {
          print(
            '   ⚠️  build-affecting inputs NOT covered by this fingerprint:',
          );
        }
        if (shown++ >= 10) {
          print('      … and ${expected.length - covered.length - 10} more');
          break;
        }
        // ignore: avoid_print
        print('      ${_rel(f, project)}');
      }
      if (shown == 0) {
        print('   ✅ coverage: all project + path-dep sources fingerprinted');
      }
    }
  }

  String _rel(final String path, final String project) =>
      p.relative(path, from: project);
}
