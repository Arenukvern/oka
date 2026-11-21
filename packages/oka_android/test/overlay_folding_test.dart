import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  group('foldOverlayDependencies', () {
    test('no overlays → overrides returned untouched', () {
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );
      const overrides = PipelineOverrides(extraDeps: ['a:b:1.0']);
      expect(
        identical(foldOverlayDependencies(ctx, overrides), overrides),
        isTrue,
      );
    });

    test('android excludes filter extraDeps (exact + group:artifact:*)', () {
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
        overlays: [
          Overlay(
            name: 'gms-free',
            excludeNativeDependencies: {
              'android': ['com.google.android.gms:*'],
            },
          ),
        ],
      );
      const overrides = PipelineOverrides(
        extraDeps: [
          'androidx.core:core-ktx:1.13.1',
          'com.google.android.gms:play-services-base:18.5.0',
        ],
      );
      final folded = foldOverlayDependencies(ctx, overrides);
      expect(folded.extraDeps, ['androidx.core:core-ktx:1.13.1']);
    });

    test('non-android overlays do not touch Android deps', () {
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
        overlays: [
          Overlay(
            name: 'steamworks',
            excludeNativeDependencies: {
              'windows': ['some_native_lib'],
            },
          ),
        ],
      );
      const overrides = PipelineOverrides(
        extraDeps: ['com.android.billingclient:billing-ktx:7.1.1'],
      );
      expect(foldOverlayDependencies(ctx, overrides).extraDeps, [
        'com.android.billingclient:billing-ktx:7.1.1',
      ]);
    });

    test('android extras append after kept deps', () {
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
        overlays: [
          Overlay(
            name: 'gms',
            extraNativeDependencies: {
              'android': ['com.android.billingclient:billing-ktx:7.1.1'],
            },
          ),
        ],
      );
      const overrides = PipelineOverrides(extraDeps: ['androidx.core:core:1']);
      expect(foldOverlayDependencies(ctx, overrides).extraDeps, [
        'androidx.core:core:1',
        'com.android.billingclient:billing-ktx:7.1.1',
      ]);
    });

    test('matchesDependencyExclusion: exact and prefix patterns only', () {
      expect(matchesDependencyExclusion('a:b:1', ['a:b:1']), isTrue);
      expect(matchesDependencyExclusion('a:b:1', ['a:*']), isTrue);
      expect(matchesDependencyExclusion('a:b:1', ['ab:*']), isFalse);
      expect(matchesDependencyExclusion('a:b:1', ['a:b:2']), isFalse);
    });
  });
}
