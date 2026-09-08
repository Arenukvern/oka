// ADR-0016 W0 — the web station must never leak Android in.
//
// Web is explicitly NOT a PlatformPipeline (ADR-0016), and oka_web must
// not import or emit anything from oka_android: web's compile step is a
// named delegation to `flutter build web`, and the Android station lives
// on the other side of the ADR-0015 boundary.
import 'dart:io';

import 'package:test/test.dart';

/// Scans every .dart file under [root] recursively.
List<File> dartFiles(final Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((final f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  final libRoot = Directory('lib');
  final testRoot = Directory('test');

  test('oka_web sources never import oka_android', () {
    final violations = <String>[];
    // This gate test itself documents the law (mentions oka_android) —
    // scan production sources + every other test file.
    final self = File('test/no_android_leakage_test.dart');
    for (final file in [
      ...dartFiles(libRoot),
      ...dartFiles(testRoot),
    ].where((final f) => f.path != self.path)) {
      final content = file.readAsStringSync();
      if (content.contains('oka_android')) {
        violations.add(file.path);
      }
    }
    expect(
      violations,
      isEmpty,
      reason: 'oka_web must not reference oka_android '
          '(ADR-0016: web is not a platform pipeline; ADR-0015 boundary). '
          'Violating files: $violations',
    );
  });

  test('oka_web sources contain no Android platform markers', () {
    final markers = RegExp(
      r'\baapt2?\b|\bapksigner\b|\bd8\b|\badb\b|apk-path|aab-path',
      caseSensitive: false,
    );
    final violations = <String>[];
    for (final file in dartFiles(libRoot)) {
      final content = file.readAsStringSync();
      // Strict markers only: tool invocations and Android artifact ids.
      // Doc-comment prose (e.g. "no-Gradle law" references) is not
      // machinery — the package:oka_android scan above is the import gate.
      if (markers.allMatches(content).isNotEmpty) {
        violations.add('${file.path}: '
            '${markers.allMatches(content).map((final m) => m.group(0)).toSet()}');
      }
    }
    expect(
      violations,
      isEmpty,
      reason: 'oka_web must contain no Android build machinery. '
          'Violations: $violations',
    );
  });
}
