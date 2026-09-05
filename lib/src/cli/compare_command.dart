import 'dart:io';

import 'package:args/args.dart';

import 'package:oka_android/oka_android.dart';

/// `oka compare <file1> <file2>` — formal byte-equivalence gate (ADR-0007).
///
/// Diffs two APK/AAB artifacts: `aapt2 dump badging` (package, version,
/// permissions, intent-filter metadata) + zip entry lists. Exits non-zero on
/// differences unless `--quiet`.
class CompareCommand {
  Future<void> run(List<String> args) async {
    final parser = ArgParser()
      ..addFlag(
        'quiet',
        abbr: 'q',
        negatable: false,
        help: 'Suppress output; differences do not fail (exit 0)',
      )
      ..addFlag(
        'skip-badging',
        negatable: false,
        help: 'Skip the aapt2 badging diff (zip entries only)',
      );
    final results = parser.parse(args);
    final quiet = results['quiet'] as bool;
    final skipBadging = results['skip-badging'] as bool;
    final files = results.rest;

    if (files.length != 2) {
      print('Usage: oka compare <apk-or-aab-1> <apk-or-aab-2> [--quiet]');
      exit(2);
    }

    for (final f in files) {
      if (!File(f).existsSync()) {
        print('❌ not found: $f');
        exit(2);
      }
    }

    String? aapt2;
    if (!skipBadging) {
      aapt2 = await locateAapt2ForCompare();
    }

    final comparison = await compareArtifacts(
      files[0],
      files[1],
      aapt2Path: aapt2,
    );

    if (quiet) {
      exit(0);
    }

    print(comparison.report());
    exit(comparison.hasDifferences ? 1 : 0);
  }
}
