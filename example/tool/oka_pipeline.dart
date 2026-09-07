/// Example: full-Dart project config (ADR-0010) — no oka.yaml at all.
///
/// This file IS the project configuration: strictly typed, const-constructible,
/// programmable (flavor logic, shared bases, compile-time typos instead of
/// silent YAML key typos). `oka build` discovers it by convention
/// (`tool/oka_pipeline.dart`) and delegates here; `okaRun` performs the
/// boilerplate (arg parsing, dart-defines, SDK/cache dirs, pipeline run).
///
/// Run it (from the example project root):
///
/// ```bash
/// dart run tool/oka_pipeline.dart            # debug build
/// dart run tool/oka_pipeline.dart --print-config   # merged config JSON
/// oka explain                                 # validated plan (no tools)
/// ```
///
/// Precedence reminder: built-in defaults < oka.yaml (if kept) < this file
/// < CLI args (--release/--aab/--abi/--target/--dart-define).
library;

import 'dart:io';

import 'package:oka_android/oka_android.dart';

/// Steps shared by APK and AAB builds (identical through dependency
/// resolution; the packaging tail differs per artifact type).
List<BuildStep> _commonSteps() => [
  EnsureAndroidSdkStep(),
  ResolveAbisStep(),
  PluginPackagingStep(),
  HostCodegenStep(),
  FlutterAssembleStep(),
  EngineExtractionStep(),
  ReleaseAotStep(),
  DependencyResolveStep(),
  // ↓ Custom step A: generate a build-info asset before packaging.
  BuildInfoStampStep(),
];

/// APK tail: single-dex compile, zipalign/apksigner packaging, APK layout
/// validation.
List<BuildStep> _apkTail() => [
  CompileAndDexStep(),
  PackageAndSignStep(),
  // Custom step B: observe the packaged artifact.
  PrintChecksumStep(),
  ValidateLayoutStep(),
];

/// AAB tail (ADR-0004): proto-format resource linking, `base/` module
/// staging + jarsigner v1, AAB layout validation.
List<BuildStep> _aabTail() => [
  CompileProtoAndDexStep(),
  PackageAndSignAabStep(),
  PrintChecksumStep(),
  ValidateAabLayoutStep(),
];

Future<void> main(final List<String> args) {
  // `oka build aab` forwards `--aab`; pick the packaging tail accordingly.
  // (Explicit step lists bypass AndroidPipeline's buildAab default — a
  // composed pipeline owns APK-vs-AAB itself.)
  final wantsAab = args.contains('--aab');
  return okaRun(
    args,
    oka: Oka(
      pipelines: [
        AndroidPipeline(
          // The old `android:` oka.yaml section — strictly typed.
          config: const AndroidBuild(
            name: 'example',
            packageName: 'com.example.example',
            compileSdk: '34',
            minSdk: '21',
            targetSdk: '34',
            javaVersion: 11,
            versionCode: 1,
            versionName: '1.0.0+1',
            sourceDirs: ['src/main/java', 'src/main/kotlin'],
            abis: ['arm64-v8a', 'armeabi-v7a'],
          ),
          // The old `flutter:` oka.yaml section.
          flutterConfig: const FlutterBuild(
            entrypoint: 'lib/main.dart',
            assets: ['assets/'],
            buildMode: 'debug',
            targetPlatform: 'android-arm64',
            treeShakeIcons: true,
            enableHotReload: true,
          ),
          // The old `pipeline:` fast-settings + android.icon/res_dirs.
          overrides: const PipelineOverrides(
            extraDeps: ['com.squareup.okhttp3:okhttp:4.12.0'],
            extraAssets: [
              (from: 'assets/hello.txt', to: 'assets/hello.txt'),
              (
                from: 'build_generated_config.json',
                to: 'generated-config.json',
              ),
            ],
            localAars: ['libs/testnative.aar'],
            icon: IconConfig(
              backgroundColor: '#E8F5E9',
              vector: 'assets/icon/foreground.xml',
            ),
            deeplinks: [
              DeeplinkConfig(
                scheme: 'https',
                host: 'oka.example.com',
                pathPrefix: '/app',
              ),
            ],
          ),
          // Compose the shared prefix with the mode-specific packaging tail.
          steps: [..._commonSteps(), ...(wantsAab ? _aabTail() : _apkTail())],
        ),
      ],
      // ADR-0015: project-declared targets. `oka run device` (alias:
      // `oka launch`) installs the newest built APK, launches it, and
      // scans the device log for failure signatures.
      targets: const [DeviceTarget()],
    ),
  );
}

/// Custom step example A: writes a build-stamp file into flutter_assets,
/// demonstrating typed artifact reads/writes.
class BuildInfoStampStep extends BuildStep {
  @override
  String get name => 'build-info-stamp';

  @override
  Set<Artifact<Object>> get requires => {flutterAssetsDir};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final out = File('${ctx.buildDir}/assemble/flutter_assets/build_info.txt');
    await out.parent.create(recursive: true);
    await out.writeAsString(
      'built=${DateTime.now().toIso8601String()}\n'
      'abis=${state.abis.join(',')}\n',
    );
    print('🧩 build stamp written: ${out.path}');
    return StepResult.success();
  }
}

/// Custom step example B: observes the packaged artifact without modifying it.
class PrintChecksumStep extends BuildStep {
  @override
  String get name => 'print-checksum';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final apk = state.apkPath;
    if (apk == null) return StepResult.failure('no apk staged');
    final bytes = await File(apk).length();
    final kind = apk.endsWith('.aab') ? 'AAB' : 'APK';
    print('🔐 $kind: $apk (${(bytes / 1024 / 1024).toStringAsFixed(1)} MB)');
    return StepResult.success();
  }
}
