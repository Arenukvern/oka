// ADR-0013 two-axis law, demonstrated (ADR-0014 P2): the Huawei store
// target composes a GMS-excluding AndroidBuild variant, and the **existing**
// artifact validator rejects a GMS-dependent step in that composition
// *before any tool runs*.
//
// The rejection uses the public checker only — Pipeline.validate /
// describeTarget — no new validator, no new mechanism.
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:oka_huawei/oka_huawei.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A step that cannot ship in a GMS-free artifact: it consumes a
/// GMS-provided dependency (Play Billing). Its `run` throws — if it ever
/// executes, the "rejected before any tool runs" law is broken.
class PlayBillingStep extends BuildStep {
  PlayBillingStep();

  /// The GMS-provided artifact this step requires (typed seam).
  static final billing =
      gmsDependencyArtifact('com.android.billingclient:billing-ktx');

  static bool everRan = false;

  @override
  String get name => 'play-billing';

  @override
  Set<Artifact<Object>> get requires => {billing};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) {
    everRan = true;
    return Future<StepResult>.value(
      StepResult.success({'billing': 'resolved from the GMS-provided artifact'}),
    );
  }
}

/// A composition root declaring the Huawei variant *with* a GMS-dependent
/// step — the mis-wiring the validator must catch.
class MiswiredHuaweiTarget extends Target {
  const MiswiredHuaweiTarget(this.variant);

  final HuaweiBuildVariant variant;

  @override
  String get name => 'publish-huawei-miswired';

  @override
  String get description => 'mis-wired composition (test fixture)';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [
        ...compileVariantSteps(ctx),
        PlayBillingStep(),
      ];
}

/// A valid target: the variant + a step that needs no GMS artifact.
class ValidHuaweiTarget extends Target {
  const ValidHuaweiTarget(this.variant);

  final HuaweiBuildVariant variant;

  @override
  String get name => 'publish-huawei-variant';

  @override
  String get description => 'the GMS-excluded variant composition';

  @override
  List<BuildStep> compile(final BuildContext ctx) => compileVariantSteps(ctx);
}

/// The variant's composition steps: stage the AAB the way the real target
/// does (a stand-in for the platform build's tail).
List<BuildStep> compileVariantSteps(final BuildContext ctx) => [
      HuaweiStageAabStep(),
    ];

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_huawei_gms_test_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  BuildContext makeCtx() => BuildContext(
        projectPath: tmp.path,
        buildDir: p.join(tmp.path, 'build'),
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );

  group('GMS classification (oka_android seam, as data)', () {
    test('GMS families are classified; androidx and others are not', () {
      const gms = [
        'com.android.billingclient:billing-ktx:7.0.0',
        'com.google.android.gms:play-services-base:18.2.0',
        'com.google.android.play:core:1.10.3',
        'com.google.firebase:firebase-messaging:23.1.0',
      ];
      const other = [
        'androidx.core:core-ktx:1.13.1',
        'io.flutter:flutter_embedding:1.0.0',
      ];
      for (final c in gms) {
        expect(isGmsCoordinate(c), isTrue, reason: c);
      }
      for (final c in other) {
        expect(isGmsCoordinate(c), isFalse, reason: c);
      }
    });

    test('splitGmsDependencies partitions extraDeps', () {
      final split = splitGmsDependencies(const [
        'androidx.core:core-ktx:1.13.1',
        'com.android.billingclient:billing-ktx:7.0.0',
      ]);
      expect(split.other, ['androidx.core:core-ktx:1.13.1']);
      expect(split.gms, ['com.android.billingclient:billing-ktx:7.0.0']);
    });

    test('artifact ids are version-free and typed', () {
      final a = gmsDependencyArtifact('com.android.billingclient:billing-ktx');
      expect(a.id, 'gms-dep:com.android.billingclient:billing-ktx');
      expect(isGmsDependencyArtifactId(a.id), isTrue);
      expect(isGmsDependencyArtifactId('apk-path'), isFalse);
    });
  });

  group('HuaweiBuildVariant — the GMS-excluding composition', () {
    test('GMS coordinates are excluded; everything else passes through',
        () {
      const variant = HuaweiBuildVariant(
        overrides: PipelineOverrides(
          extraDeps: [
            'androidx.core:core-ktx:1.13.1',
            'com.android.billingclient:billing-ktx:7.0.0',
            'com.google.android.gms:play-services-ads:22.0.0',
          ],
        ),
      );
      expect(variant.gmsFreeExtraDeps, ['androidx.core:core-ktx:1.13.1']);
      expect(variant.excludedGmsDeps, [
        'com.android.billingclient:billing-ktx:7.0.0',
        'com.google.android.gms:play-services-ads:22.0.0',
      ]);
      // The overrides a Huawei artifact is actually built from:
      expect(variant.gmsFreeOverrides.extraDeps, ['androidx.core:core-ktx:1.13.1']);
      // The base config is untouched.
      expect(variant.android, const AndroidBuild());
    });

    test('the target composes the variant (two-axis law)', () {
      const variant = HuaweiBuildVariant(
        android: AndroidBuild(packageName: 'dev.example.app'),
      );
      const target = HuaweiPublishTarget(variant: variant);
      expect(target.variant, variant);
      expect(target.toString(), contains('dev.example.app'));
    });
  });

  group('composition-time safety — the existing validator rejects GMS '
      'mismatch before any tool runs', () {
    tearDown(() {
      expect(
        PlayBillingStep.everRan,
        isFalse,
        reason: 'a GMS-dependent step executed in a GMS-excluded '
            'composition — the validator failed its only job',
      );
    });

    test('Pipeline.validate rejects the GMS-requiring step (no provider)',
        () {
      final pipeline = Pipeline([PlayBillingStep()]);
      final error = pipeline.validate();
      expect(error, isNotNull);
      expect(error, contains('play-billing'));
      expect(error, contains('gms-dep:com.android.billingclient:billing-ktx'));
      expect(error, contains('no earlier step provides it'));
    });

    test('describeTarget marks the mis-wired target invalid — the same '
        'failure `oka run` reports before executing anything', () {
      const variant = HuaweiBuildVariant();
      final chain = describeTarget(const MiswiredHuaweiTarget(variant), makeCtx());
      expect(chain.isValid, isFalse);
      expect(chain.validationError, contains('gms-dep:'));
    });

    test('the same step validates and runs when the composition includes '
        'GMS (the positive control)', () async {
      final jar = File(p.join(tmp.path, 'billing.jar'))
        ..writeAsStringSync('synthetic jar bytes');
      final pipeline = Pipeline([
        GmsDependencyProviderStep(
          resolvedPaths: {
            'com.android.billingclient:billing-ktx': jar.path,
          },
        ),
        PlayBillingStep(),
      ]);
      expect(pipeline.validate(), isNull);
      PlayBillingStep.everRan = false;

      final ctx = makeCtx();
      final state = PipelineState();
      final result = await pipeline.run(ctx, initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      expect(
        state[gmsDependencyArtifactId('com.android.billingclient:billing-ktx')],
        jar.path,
      );
      // The positive control ran; reset so tearDown's law check stays
      // meaningful for the other tests.
      PlayBillingStep.everRan = false;
    });

    test('the GMS provider fails when its resolved file is missing', () async {
      final pipeline = Pipeline([
        GmsDependencyProviderStep(
          resolvedPaths: {
            'com.android.billingclient:billing-ktx':
                p.join(tmp.path, 'missing.jar'),
          },
        ),
      ]);
      expect(pipeline.validate(), isNull);
      final result = await pipeline.run(makeCtx());
      expect(result.ok, isFalse);
      expect(result.error, contains('missing.jar'));
      expect(result.error, contains('billing-ktx'));
    });

    test('the valid variant target compiles cleanly', () {
      const variant = HuaweiBuildVariant();
      final chain = describeTarget(const ValidHuaweiTarget(variant), makeCtx());
      expect(chain.isValid, isTrue, reason: chain.validationError);
      expect(
        chain.steps.map((final s) => s.name).toList(),
        ['huawei-stage-aab'],
      );
    });
  });
}
