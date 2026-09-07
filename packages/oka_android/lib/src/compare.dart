/// `oka compare` — formal byte-equivalence gate for refactors (ADR-0007).
///
/// Compares two APK/AAB artifacts:
/// - `aapt2 dump badging` diff: package name, versionCode/Name, permissions,
///   intent-filter/launchable metadata (plus a full badging-line diff);
/// - zip entry list diff: entries only in A / only in B, and common entries
///   whose content changed (crc32).
///
/// Differences make the CLI exit non-zero (escape: `--quiet`), so refactors
/// can claim "byte-equivalent output" with a checkable command instead of a
/// claim in a PR description.
library;
import 'dart:io';

import 'package:archive/archive.dart';

import 'build/toolchain.dart';

/// Parsed subset of `aapt2 dump badging` output.
class BadgingInfo {

  const BadgingInfo({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    this.usesPermissions = const [],
    this.minSdkVersion,
    this.targetSdkVersion,
    this.launchableActivity,
    this.intentFilters = const {},
    this.allLines = const [],
  });
  final String packageName;
  final String versionCode;
  final String versionName;
  final List<String> usesPermissions;
  final String? minSdkVersion;
  final String? targetSdkVersion;
  final String? launchableActivity;
  /// Intent-filter lines (actions/categories) when the badging output
  /// carries them, keyed by badging key (e.g. `intent-filter-action`).
  final Map<String, List<String>> intentFilters;
  /// Every raw badging line (sorted, trimmed) — the full-diff fallback.
  final List<String> allLines;
}

final _attrRe = RegExp(r"([a-zA-Z][a-zA-Z0-9_\-]*)='([^']*)'");

/// Parse `aapt2 dump badging` output into a [BadgingInfo].
BadgingInfo parseBadging(final String output) {
  var packageName = '';
  var versionCode = '';
  var versionName = '';
  String? minSdk;
  String? targetSdk;
  String? launchable;
  final permissions = <String>{};
  final intentFilters = <String, List<String>>{};
  final allLines = <String>[];

  for (final raw in output.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      continue;
    }
    allLines.add(line);

    // Badging lines are `key: payload` or `key:payload` (sdkVersion style).
    final colon = line.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    final key = line.substring(0, colon).trim();
    final payload = line.substring(colon + 1).trim();

    switch (key) {
      case 'package':
        final attrs = _attrRe.allMatches(payload);
        for (final m in attrs) {
          switch (m.group(1)) {
            case 'name':
              packageName = m.group(2)!;
            case 'versionCode':
              versionCode = m.group(2)!;
            case 'versionName':
              versionName = m.group(2)!;
          }
        }
      case 'uses-permission' when payload.startsWith("name='"):
        final m = _attrRe.firstMatch(payload);
        if (m != null) {
          permissions.add(m.group(2)!);
        }
      case 'sdkVersion' || 'minSdkVersion':
        minSdk = payload.replaceAll("'", '');
      case 'targetSdkVersion':
        targetSdk = payload.replaceAll("'", '');
      case 'launchable-activity':
        final m = _attrRe.firstMatch(payload);
        if (m != null) {
          launchable = m.group(2)!;
        }
      default:
        if (key.contains('intent-filter') || key == 'action' ||
            key == 'category') {
          intentFilters.putIfAbsent(key, () => []).add(payload);
        }
    }
  }

  return BadgingInfo(
    packageName: packageName,
    versionCode: versionCode,
    versionName: versionName,
    usesPermissions: permissions.toList()..sort(),
    minSdkVersion: minSdk,
    targetSdkVersion: targetSdk,
    launchableActivity: launchable,
    intentFilters: Map.unmodifiable(
      intentFilters.map((final k, final v) => MapEntry(k, v..sort())),
    ),
    allLines: allLines..sort(),
  );
}

/// Zip-level comparison result for the entry lists of two artifacts.
class ZipEntryDiff {

  const ZipEntryDiff({
    required this.onlyInA,
    required this.onlyInB,
    required this.changedContent,
  });
  /// Entry names present only in artifact A (sorted).
  final List<String> onlyInA;
  /// Entry names present only in artifact B (sorted).
  final List<String> onlyInB;
  /// Common entries whose content changed (crc32 mismatch).
  final List<String> changedContent;

  bool get isEmpty => onlyInA.isEmpty && onlyInB.isEmpty && changedContent.isEmpty;
}

/// Compare the zip entry lists of two APK/AAB files.
///
/// Entry names only (directories included as-is); common entries are compared
/// by crc32 to catch silent content swaps. Timestamps and compression
/// metadata are ignored — the gate targets content equivalence.
ZipEntryDiff compareZipEntries(final String pathA, final String pathB) {
  final entriesA = _entryCrcs(pathA);
  final entriesB = _entryCrcs(pathB);
  final onlyA = entriesA.keys.where((final n) => !entriesB.containsKey(n)).toList()
    ..sort();
  final onlyB = entriesB.keys.where((final n) => !entriesA.containsKey(n)).toList()
    ..sort();
  final changed = entriesA.keys
      .where(
        (final n) =>
            entriesB.containsKey(n) &&
            entriesB[n] != entriesA[n] &&
            entriesA[n] != null,
      )
      .toList()
    ..sort();
  return ZipEntryDiff(
    onlyInA: onlyA,
    onlyInB: onlyB,
    changedContent: changed,
  );
}

Map<String, int?> _entryCrcs(final String path) {
  final bytes = File(path).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  return {
    for (final f in archive) f.name: f.crc32,
  };
}

/// Full comparison result for two APK/AAB artifacts.
class ArtifactComparison {

  const ArtifactComparison({
    required this.pathA,
    required this.pathB,
    required this.badgingDifferences,
    required this.zipDiff,
    this.badgingA,
    this.badgingB,
    this.badgingSkippedReason,
  });
  final String pathA;
  final String pathB;
  final BadgingInfo? badgingA;
  final BadgingInfo? badgingB;
  /// Human-readable badging differences (empty when badging matched or was
  /// unavailable).
  final List<String> badgingDifferences;
  /// Non-null when badging could not be dumped (e.g. no aapt2 found).
  final String? badgingSkippedReason;
  final ZipEntryDiff zipDiff;

  bool get hasDifferences =>
      badgingDifferences.isNotEmpty ||
      zipDiff.onlyInA.isNotEmpty ||
      zipDiff.onlyInB.isNotEmpty ||
      zipDiff.changedContent.isNotEmpty;

  /// Multi-line human-readable report.
  String report() {
    final b = StringBuffer();
    b.writeln('🆚 oka compare');
    b.writeln('   A: $pathA');
    b.writeln('   B: $pathB');
    if (badgingSkippedReason != null) {
      b.writeln('⚠️  badging skipped: $badgingSkippedReason');
    }
    if (badgingDifferences.isEmpty && badgingSkippedReason == null) {
      b.writeln('✅ badging identical');
    }
    for (final d in badgingDifferences) {
      b.writeln('❌ badging: $d');
    }
    if (zipDiff.isEmpty) {
      b.writeln('✅ zip entries identical');
    } else {
      for (final n in zipDiff.onlyInA) {
        b.writeln('❌ entry only in A: $n');
      }
      for (final n in zipDiff.onlyInB) {
        b.writeln('❌ entry only in B: $n');
      }
      for (final n in zipDiff.changedContent) {
        b.writeln('❌ entry content changed: $n');
      }
    }
    b.writeln(
      hasDifferences ? '❌ artifacts differ' : '✅ artifacts are equivalent',
    );
    return b.toString().trimRight();
  }
}

/// Compare two APK/AAB artifacts (badging + zip entries).
///
/// [dumpBadging] injects the aapt2 invocation for tests; by default the
/// binary is located via [aapt2Path]. When aapt2 is unavailable the badging
/// section is skipped with a reason — the zip diff still applies.
Future<ArtifactComparison> compareArtifacts(
  final String pathA,
  final String pathB, {
  final String? aapt2Path,
  final Future<String> Function(String aapt2, String artifact)? dumpBadging,
}) async {
  final zipDiff = compareZipEntries(pathA, pathB);

  BadgingInfo? badgingA;
  BadgingInfo? badgingB;
  String? skipReason;
  final usesInjectedDumper = dumpBadging != null;
  final dumper = dumpBadging ?? _defaultDumpBadging;
  if (aapt2Path == null && !usesInjectedDumper) {
    skipReason = 'no aapt2 found (set ANDROID_SDK_ROOT or run `oka get '
        'android-sdk`) — zip entries still compared';
  } else {
    try {
      badgingA = parseBadging(await dumper(aapt2Path ?? '', pathA));
      badgingB = parseBadging(await dumper(aapt2Path ?? '', pathB));
    } on Exception catch (e) {
      skipReason = 'aapt2 dump badging failed: $e';
      badgingA = null;
      badgingB = null;
    }
  }

  return ArtifactComparison(
    pathA: pathA,
    pathB: pathB,
    badgingA: badgingA,
    badgingB: badgingB,
    badgingDifferences: _badgingDifferences(badgingA, badgingB),
    badgingSkippedReason: skipReason,
    zipDiff: zipDiff,
  );
}

Future<String> _defaultDumpBadging(final String aapt2, final String artifact) async {
  final result = await Process.run(aapt2, ['dump', 'badging', artifact]);
  if (result.exitCode != 0) {
    throw Exception(
      'aapt2 dump badging failed for $artifact '
      '(exit ${result.exitCode}): ${result.stderr}',
    );
  }
  return result.stdout as String;
}

List<String> _badgingDifferences(final BadgingInfo? a, final BadgingInfo? b) {
  if (a == null || b == null) {
    return const [];
  }
  final diffs = <String>[];
  if (a.packageName != b.packageName) {
    diffs.add('package name: ${a.packageName} vs ${b.packageName}');
  }
  if (a.versionCode != b.versionCode) {
    diffs.add('versionCode: ${a.versionCode} vs ${b.versionCode}');
  }
  if (a.versionName != b.versionName) {
    diffs.add('versionName: ${a.versionName} vs ${b.versionName}');
  }
  if (a.minSdkVersion != b.minSdkVersion) {
    diffs.add('minSdk: ${a.minSdkVersion} vs ${b.minSdkVersion}');
  }
  if (a.targetSdkVersion != b.targetSdkVersion) {
    diffs.add('targetSdk: ${a.targetSdkVersion} vs ${b.targetSdkVersion}');
  }
  if (a.launchableActivity != b.launchableActivity) {
    diffs.add(
      'launchable-activity: ${a.launchableActivity} vs ${b.launchableActivity}',
    );
  }
  final permsOnlyA = a.usesPermissions
      .where((final x) => !b.usesPermissions.contains(x))
      .toList();
  final permsOnlyB = b.usesPermissions
      .where((final x) => !a.usesPermissions.contains(x))
      .toList();
  for (final perm in permsOnlyA) {
    diffs.add('permission only in A: $perm');
  }
  for (final perm in permsOnlyB) {
    diffs.add('permission only in B: $perm');
  }
  // Full-output fallback catches anything the structured extraction missed
  // (intent-filter metadata, labels, features, …).
  final linesOnlyA = a.allLines.where((final l) => !b.allLines.contains(l)).toList();
  final linesOnlyB = b.allLines.where((final l) => !a.allLines.contains(l)).toList();
  if (diffs.isEmpty && (linesOnlyA.isNotEmpty || linesOnlyB.isNotEmpty)) {
    for (final l in linesOnlyA.take(20)) {
      diffs.add('badging line only in A: $l');
    }
    for (final l in linesOnlyB.take(20)) {
      diffs.add('badging line only in B: $l');
    }
  }
  return diffs;
}

/// Convenience: locate aapt2 for [compareArtifacts] (null when unavailable).
Future<String?> locateAapt2ForCompare() async {
  try {
    return await ResolvedToolchain().findAapt2();
  } on Exception {
    return null;
  }
}
