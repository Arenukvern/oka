import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

// Project-composed keys (ADR-0056): the well-known constants live in the
// store packages; a test composes its own values.
const storeKeyGooglePlay = StoreKey('google-play');
const storeKeyRuStore = StoreKey('rustore');
const storeKeyAppGallery = StoreKey('appgallery');

/// A minimal pipeline stub: platform identity + a no-op run — deliveries
/// validate composition without executing anything.
class _StubPipeline implements PlatformPipeline {
  const _StubPipeline(this.platform);
  @override
  final String platform;
  @override
  Map<String, dynamic> get configOverrides => const {};
  @override
  Future<StepResult> run(BuildContext ctx) async => StepResult.success();
}

/// A minimal channel stub: capability + a one-step publish tail.
class _StubChannel extends PublishTarget {
  const _StubChannel({
    this.acceptedPlatforms = const {},
    this.acceptedArtifactFormats = const {},
    this.requiredOverlays = const {},
    this.prohibitedOverlays = const {},
  });
  @override
  final Set<String> acceptedPlatforms;
  @override
  final Set<String> acceptedArtifactFormats;
  @override
  final Set<String> requiredOverlays;
  @override
  final Set<String> prohibitedOverlays;

  @override
  String get name => 'publish-stub';

  @override
  String get description => 'stub channel';

  @override
  String get endpoint => 'Stub Store API';

  @override
  String get track => 'internal';

  @override
  String get artifactId => 'stub-artifact';

  @override
  BuildStep uploadStep(BuildContext ctx) => _StubUploadStep();
}

class _StubUploadStep extends BuildStep {
  // The codebase convention (StageAabStep): the artifact as a static const
  // field — a const SET of Artifact is rejected (custom ==), the field is not.
  static const artifact = Artifact<String>('stub-artifact');

  @override
  String get name => 'stub-upload';
  @override
  Set<Artifact<Object>> get requires => {artifact};
  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async =>
      StepResult.success();
}

const _gms = Overlay(
  name: 'gms',
  description: 'Google Mobile Services',
  defines: {'USE_GMS': 'true'},
  extraNativeDependencies: {
    'android': ['com.android.billingclient:billing-ktx:7.1.1'],
  },
);
const _hmsFree = Overlay(
  name: 'hms-free',
  description: 'GMS-free set',
  excludeNativeDependencies: {
    'android': ['com.google.android.gms:*'],
  },
);

void main() {
  group('Overlay', () {
    test('validates names and platform selectors', () {
      expect(_gms.validate(), isEmpty);
      expect(
        const Overlay(name: 'GMS').validate(),
        everyElement(contains('invalid overlay name')),
      );
      expect(
        const Overlay(
          name: 'ok-name',
          extraNativeDependencies: {'Bad Platform': []},
        ).validate(),
        everyElement(contains('invalid platform selector')),
      );
    });

    test('round-trips through JSON (build-context serialization)', () {
      final encoded = _gms.toJson();
      final decoded = Overlay.fromJson(encoded);
      expect(decoded, _gms);
      expect(decoded.extrasFor('android'), _gms.extrasFor('android'));
    });

    test('equality is field-wise', () {
      expect(
        _gms,
        const Overlay(
          name: 'gms',
          description: 'Google Mobile Services',
          defines: {'USE_GMS': 'true'},
          extraNativeDependencies: {
            'android': ['com.android.billingclient:billing-ktx:7.1.1'],
          },
        ),
      );
      expect(_gms == _hmsFree, isFalse);
    });
  });

  group('Variant.applyTo', () {
    test('applies entrypoint, defines (under ctx), and overlays', () {
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '/p/.oka_cache/build/debug',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
        dartDefines: {'CLI_KEY': 'cli'},
      );
      const variant = Variant(
        key: storeKeyRuStore,
        entrypoint: 'lib/entrypoints/main_store_rustore.dart',
        defines: {'VARIANT_KEY': 'v'},
        overlays: [_gms],
      );
      final out = variant.applyTo(ctx);

      expect(out.targetOverride, 'lib/entrypoints/main_store_rustore.dart');
      // Variant + overlay defines land UNDER the CLI defines.
      expect(out.dartDefines['VARIANT_KEY'], 'v');
      expect(out.dartDefines['USE_GMS'], 'true');
      expect(out.dartDefines['CLI_KEY'], 'cli');
      // The store identity reaches the binary (ADR-0055 — the boot can
      // verify its binding against the composition).
      expect(out.dartDefines[okaStoreDefine], 'rustore');
      expect(out.overlays.map((o) => o.name), ['gms']);
    });

    test('a key-only variant still bakes the identity define', () {
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );
      const variant = Variant(key: storeKeyGooglePlay);
      final out = variant.applyTo(ctx);
      expect(out.dartDefines, {okaStoreDefine: 'google-play'});
    });

    test('CLI --target wins over the variant entrypoint', () {
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
        targetOverride: 'lib/main_cli.dart',
      );
      final out = const Variant(
        key: storeKeyRuStore,
        entrypoint: 'lib/entrypoints/main_store_rustore.dart',
      ).applyTo(ctx);
      expect(out.targetOverride, 'lib/main_cli.dart');
    });

    test('later overlays win over earlier ones (no hidden merging)', () {
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );
      const first = Overlay(name: 'a', defines: {'SHARED': 'first'});
      const second = Overlay(name: 'b', defines: {'SHARED': 'second'});
      final out = const Variant(overlays: [first, second]).applyTo(ctx);
      expect(out.dartDefines['SHARED'], 'second');
    });

    test('an empty variant returns the context unchanged (identity)', () {
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );
      expect(identical(const Variant().applyTo(ctx), ctx), isTrue);
    });

    test('validates key, entrypoint shape, and overlays', () {
      final issues = const Variant(
        key: StoreKey('Bad Key'),
        entrypoint: '../escape.dart',
        overlays: [Overlay(name: 'Bad Overlay')],
      ).validate();
      expect(issues.length, 3);
      expect(issues.first, contains('invalid store key'));
      expect(issues[1], contains('project-relative'));
      expect(issues[2], contains('invalid overlay name'));
    });
  });

  group('DeliveryTarget', () {
    test('composes pipeline steps + channel publish tail', () {
      const delivery = DeliveryTarget(
        name: 'app-stub',
        pipeline: _StubPipeline('android'),
        channel: _StubChannel(),
        buildAab: true,
      );
      final steps = delivery.compile(BuildContext.empty);
      expect(steps.first.name, 'run-pipeline:android');
      // The channel tail: stage (from StageAabStep in real channels) is a
      // stub-free chain here — the stub channel contributes only its
      // upload step.
      expect(steps.last.name, 'stub-upload');
    });

    test('applies buildAab through transformContext', () {
      const delivery = DeliveryTarget(
        name: 'app-stub',
        pipeline: _StubPipeline('android'),
        buildAab: true,
      );
      final out = delivery.transformContext(BuildContext.empty);
      expect(out.buildAab, isTrue);
      expect(delivery.effectiveArtifactFormat, 'aab');
    });

    test('channel capability violations fail before any tool runs', () {
      // GMS-free store + GMS overlay + wrong format: three issues, one
      // message, nothing compiled.
      const delivery = DeliveryTarget(
        name: 'app-bad',
        pipeline: _StubPipeline('ios'),
        variant: Variant(key: storeKeyAppGallery, overlays: [_gms]),
        channel: _StubChannel(
          acceptedPlatforms: {'android'},
          acceptedArtifactFormats: {'aab'},
          prohibitedOverlays: {'gms'},
        ),
      );
      expect(
        () => delivery.compile(BuildContext.empty),
        throwsA(
          isA<ArgumentError>()
              .having(
                (e) => e.message as String,
                'message',
                contains('accepts platforms android'),
              )
              .having(
                (e) => e.message as String,
                'message',
                contains('accepts artifact formats aab'),
              )
              .having(
                (e) => e.message as String,
                'message',
                contains('prohibits the "gms" overlay'),
              ),
        ),
      );
    });

    test('required overlays are enforced at composition time', () {
      const delivery = DeliveryTarget(
        name: 'app-missing-overlay',
        pipeline: _StubPipeline('android'),
        channel: _StubChannel(requiredOverlays: {'gms'}),
      );
      expect(
        () => delivery.compile(BuildContext.empty),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message as String,
            'message',
            contains('requires the "gms" overlay'),
          ),
        ),
      );
    });

    test('a valid composition with overlays compiles cleanly', () {
      const delivery = DeliveryTarget(
        name: 'app-good',
        pipeline: _StubPipeline('android'),
        variant: Variant(key: storeKeyGooglePlay, overlays: [_gms]),
        channel: _StubChannel(acceptedPlatforms: {'android'}),
      );
      expect(delivery.validateComposition(), isEmpty);
    });

    test('explainDetails renders the composed matrix', () {
      const delivery = DeliveryTarget(
        name: 'app-rustore',
        pipeline: _StubPipeline('android'),
        variant: Variant(key: storeKeyRuStore, overlays: [_hmsFree]),
        channel: _StubChannel(),
      );
      final lines = delivery.explainDetails(BuildContext.empty);
      expect(lines.join('\n'), contains('pipeline: android (by reference)'));
      expect(lines.join('\n'), contains('variant store: rustore'));
      expect(lines.join('\n'), contains('variant overlay: hms-free'));
      expect(lines.join('\n'), contains('channel: publish-stub'));
    });

    test('target-level dartDefines contribute nothing — the variant is '
        'the single writer (ADR-0055)', () {
      const delivery = DeliveryTarget(
        name: 'app-d',
        pipeline: _StubPipeline('android'),
        variant: Variant(defines: {'V': '1'}, overlays: [_gms]),
      );
      expect(delivery.dartDefines, isEmpty);
      // The defines still land in the context — through applyTo only:
      final out = delivery.transformContext(BuildContext.empty);
      expect(out.dartDefines['V'], '1');
      expect(out.dartDefines['USE_GMS'], 'true');
      expect(out.dartDefines[okaStoreDefine], isNull);
    });
  });

  group('Oka', () {
    test('pipelines are optional (delivery-only composition, ADR-0055)', () {
      const oka = Oka(
        targets: [
          DeliveryTarget(
            name: 'only-delivery',
            pipeline: _StubPipeline('linux'),
          ),
        ],
      );
      expect(oka.pipelines, isEmpty);
      expect(oka.targets.single.name, 'only-delivery');
    });
  });
}
