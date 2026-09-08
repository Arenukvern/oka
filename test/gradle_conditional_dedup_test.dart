import 'dart:io';

import 'package:oka_android/src/build/gradle_dep_parser.dart';
import 'package:test/test.dart';

void main() {
  group('conditional (if/else) gradle dependencies', () {
    test('marks both if/else branches with the same conditional group', () {
      const src = '''
dependencies {
    def useUnbundled = findProperty('x.useUnbundled') ?: false
    if (useUnbundled.toBoolean()) {
        implementation 'com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1'
    } else {
        implementation 'com.google.mlkit:barcode-scanning:17.3.0'
    }
    implementation 'androidx.camera:camera-lifecycle:1.6.1'
}
''';
      final deps = parseGradleDependencies(src);
      final play = deps.singleWhere((d) => d.artifactId == 'play-services-mlkit-barcode-scanning');
      final mlkit = deps.singleWhere((d) => d.artifactId == 'barcode-scanning');
      final camera = deps.singleWhere((d) => d.artifactId == 'camera-lifecycle');

      expect(play.inConditional, isTrue);
      expect(mlkit.inConditional, isTrue);
      expect(play.conditionalGroup, mlkit.conditionalGroup);
      expect(play.conditionalGroup, isNonZero);
      expect(camera.inConditional, isFalse);
      expect(camera.conditionalGroup, 0);
    });

    test('handles `else {` on its own line (rejoins the same group)', () {
      const src = '''
dependencies {
    if (flag) {
        implementation 'a:a:1.0'
    }
    else {
        implementation 'b:b:2.0'
    }
}
''';
      final deps = parseGradleDependencies(src);
      expect(deps, hasLength(2));
      expect(deps[0].conditionalGroup, deps[1].conditionalGroup);
      expect(deps[0].inConditional, isTrue);
    });

    test('handles nested conditionals and kotlin dsl add()', () {
      const src = '''
android {
    if (a) {
        if (b) {
            add("implementation", "x:y:1.0")
        }
        add("implementation", "z:w:2.0")
    }
}
''';
      final deps = parseGradleDependencies(src);
      final x = deps.singleWhere((d) => d.artifactId == 'y');
      final z = deps.singleWhere((d) => d.artifactId == 'w');
      // Nested if gets its own (inner) group.
      expect(x.inConditional, isTrue);
      expect(x.conditionalGroup, isNot(z.conditionalGroup));
      // z is still inside the outer if.
      expect(z.inConditional, isTrue);
    });

    test('mobile_scanner fixture: both ML Kit variants share one group', () {
      final src = File('test/fixtures/gradle/mobile_scanner.gradle').readAsStringSync();
      final deps = parseGradleDependencies(src);
      final play = deps.singleWhere((d) => d.artifactId == 'play-services-mlkit-barcode-scanning');
      final mlkit = deps.singleWhere(
        (d) => d.groupId == 'com.google.mlkit' && d.artifactId == 'barcode-scanning',
      );
      expect(play.inConditional, isTrue);
      expect(mlkit.inConditional, isTrue);
      expect(play.conditionalGroup, mlkit.conditionalGroup);
      // Non-conditional runtime deps stay untouched.
      for (final d in deps.where((d) => d.groupId.startsWith('androidx.camera'))) {
        expect(d.inConditional, isFalse, reason: d.coordinate);
      }
    });

    test('dedupe keeps the first variant per if/else group with a notice', () {
      final src = File('test/fixtures/gradle/mobile_scanner.gradle').readAsStringSync();
      final deps = parseGradleDependencies(src);
      final notices = <String>[];
      final kept = dedupeConditionalDeps(
        deps,
        pluginName: 'mobile_scanner',
        onNotice: notices.add,
      );

      // The first textual variant (unbundled play-services, gradle's default
      // branch declaration) wins; the other ML Kit variant is dropped.
      expect(
        kept.any((d) => d.coordinate == 'com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1'),
        isTrue,
      );
      expect(
        kept.any((d) => d.coordinate == 'com.google.mlkit:barcode-scanning:17.3.0'),
        isFalse,
      );
      // Everything else survives verbatim.
      expect(kept.length, deps.length - 1);
      expect(notices, hasLength(1));
      expect(notices.single, contains('mobile_scanner'));
      expect(notices.single, contains('play-services-mlkit-barcode-scanning'));
      expect(notices.single, contains('com.google.mlkit:barcode-scanning'));
    });

    test('dedupe keeps single-member conditional groups and unconditionals', () {
      const deps = [
        ParsedGradleDep(groupId: 'a', artifactId: 'one', version: '1', inConditional: true, conditionalGroup: 1),
        ParsedGradleDep(groupId: 'b', artifactId: 'two', version: '2'),
      ];
      final notices = <String>[];
      final kept = dedupeConditionalDeps(deps, onNotice: notices.add);
      expect(kept, hasLength(2));
      expect(notices, isEmpty);
    });

    test('rustore fixture parses unchanged (no conditional deps)', () {
      final src = File('test/fixtures/gradle/rustore_billing_api.gradle.kts').readAsStringSync();
      final deps = parseGradleDependencies(src);
      expect(deps.map((d) => d.coordinate), contains('ru.rustore.sdk:billingclient:10.1.0'));
      for (final d in deps) {
        expect(d.inConditional, isFalse, reason: d.coordinate);
      }
      expect(dedupeConditionalDeps(deps, onNotice: (_) => fail('no notice expected')), hasLength(deps.length));
    });
  });
}
