// The GMS-dependency artifact seam (ADR-0013 two-axis law; additive for
// ADR-0014 P2): classification as data, version-free artifact ids, and a
// provider step that only ever *verifies* resolved files.
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_gms_seam_test_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('classification (as data)', () {
    test('gmsGroupPrefixes covers the GMS families', () {
      expect(gmsGroupPrefixes, contains('com.google.android.gms'));
      expect(gmsGroupPrefixes, contains('com.android.billingclient'));
      expect(gmsGroupPrefixes, contains('com.google.firebase'));
    });

    test('GMS coordinates are classified regardless of version', () {
      expect(
        isGmsCoordinate('com.google.android.gms:play-services-base:18.2.0'),
        isTrue,
      );
      expect(
        isGmsCoordinate('com.android.billingclient:billing-ktx:7.0.0'),
        isTrue,
      );
      expect(isGmsCoordinate('com.google.android.play:core:1.10.3'), isTrue);
      expect(isGmsCoordinate('com.google.android.ads:ads-lite:1.0'), isTrue);
    });

    test('nested groups under a GMS prefix are classified too', () {
      expect(
        isGmsCoordinate(
          'com.google.android.gms.play-services:weird:1.0',
        ),
        isTrue,
      );
    });

    test('androidx and other groups are never classified as GMS', () {
      expect(isGmsCoordinate('androidx.core:core-ktx:1.13.1'), isFalse);
      expect(isGmsCoordinate('io.flutter:embedding:1.0.0'), isFalse);
      expect(
        // A group that merely *contains* a GMS string is not GMS.
        isGmsCoordinate('xcom.google.android.gms:fake:1.0'),
        isFalse,
      );
    });

    test('malformed coordinates are never classified as GMS', () {
      expect(isGmsCoordinate('not-a-coordinate'), isFalse);
    });

    test('splitGmsDependencies partitions and preserves order', () {
      final split = splitGmsDependencies([
        'com.google.firebase:firebase-messaging:23.1.0',
        'androidx.core:core-ktx:1.13.1',
        'com.android.billingclient:billing-ktx:7.0.0',
        'androidx.appcompat:appcompat:1.6.1',
      ]);
      expect(split.gms, [
        'com.google.firebase:firebase-messaging:23.1.0',
        'com.android.billingclient:billing-ktx:7.0.0',
      ]);
      expect(split.other, [
        'androidx.core:core-ktx:1.13.1',
        'androidx.appcompat:appcompat:1.6.1',
      ]);
    });
  });

  group('artifact ids', () {
    test('ids are version-free and prefixed', () {
      expect(
        gmsDependencyArtifactId('com.android.billingclient:billing-ktx'),
        'gms-dep:com.android.billingclient:billing-ktx',
      );
      expect(
        gmsDependencyArtifact('com.android.billingclient:billing-ktx').id,
        'gms-dep:com.android.billingclient:billing-ktx',
      );
    });

    test('identity helpers', () {
      expect(
        isGmsDependencyArtifactId('gms-dep:com.google.firebase:base'),
        isTrue,
      );
      expect(isGmsDependencyArtifactId('apk_path'), isFalse);
      expect(isGmsDependencyArtifactId('gms-dep:'), isTrue);
    });
  });

  group('GmsDependencyProviderStep', () {
    test('declares one provided artifact per resolved coordinate', () {
      final step = GmsDependencyProviderStep(
        resolvedPaths: {
          'com.android.billingclient:billing-ktx': '/tmp/billing.jar',
          'com.google.android.gms:play-services-base': '/tmp/base.jar',
        },
      );
      expect(step.provides.map((final a) => a.id), {
        'gms-dep:com.android.billingclient:billing-ktx',
        'gms-dep:com.google.android.gms:play-services-base',
      });
      expect(step.requires, isEmpty);
    });

    test('run records the resolved paths in state', () async {
      final jar = File(p.join(tmp.path, 'billing.jar'))
        ..writeAsStringSync('jar');
      final step = GmsDependencyProviderStep(
        resolvedPaths: {'com.android.billingclient:billing-ktx': jar.path},
      );
      final state = PipelineState();
      final ctx = BuildContext(
        projectPath: tmp.path,
        buildDir: p.join(tmp.path, 'build'),
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );
      final result = await step.run(ctx, state);

      expect(result.ok, isTrue, reason: result.error);
      expect(
        state[gmsDependencyArtifactId('com.android.billingclient:billing-ktx')],
        jar.path,
      );
    });

    test('run fails naming the coordinate when the file is missing',
        () async {
      final step = GmsDependencyProviderStep(
        resolvedPaths: {
          'com.android.billingclient:billing-ktx':
              p.join(tmp.path, 'missing.jar'),
        },
      );
      final ctx = BuildContext(
        projectPath: tmp.path,
        buildDir: p.join(tmp.path, 'build'),
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );
      final result = await step.run(ctx, PipelineState());

      expect(result.ok, isFalse);
      expect(result.error, contains('billing-ktx'));
      expect(result.error, contains('missing.jar'));
    });
  });
}
