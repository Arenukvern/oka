import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import '../../android_artifacts.dart';
import '../../android_state.dart';
import '../../build/apk_layout.dart';
import '../../build/artifact_checks.dart';
import '../../build/dependency_cache.dart';
import '../../build/engine_artifacts.dart';
import '../../build/flutter_assemble.dart';
import '../../build/provenance.dart';
import '../../build/startup_probe.dart';
import '../../build/toolchain.dart';
import '../../build_cache.dart';

/// Runs `flutter assemble` to produce flutter_assets.
class FlutterAssembleStep extends BuildStep {

  FlutterAssembleStep({this.toolchain, final FlutterAssembler? assembler})
    : assembler = assembler ?? FlutterAssembler();
  @override
  Set<Artifact<Object>> get requires => {abis};

  @override
  Set<Artifact<Object>> get provides => {flutterAssetsDir};

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T1).
  final ResolvedToolchain? toolchain;
  final FlutterAssembler assembler;

  /// Resolves the Android SDK without failing the step — when unavailable,
  /// the flutter tool reports its own actionable error.
  Future<String?> _locateAndroidSdkSafe(final PipelineState state) async {
    try {
      return await (toolchain ?? state.resolvedToolchain ??
              ResolvedToolchain())
          .findAndroidSdk();
    } on Exception {
      return null;
    }
  }

  /// Path-dependency pubspecs (workspace/sibling checkouts) — used to detect
  /// a stale package_config that `flutter assemble` would compile against.
  static List<File> _pathDependencyPubspecs(final String projectPath) {
    final config = packageConfigFor(projectPath);
    if (config == null) return const [];
    final roots = pathDependencyRoots(
      config.readAsStringSync(),
      configDir: p.dirname(config.path),
    );
    return [
      for (final root in roots)
        if (File(p.join(root, 'pubspec.yaml')).existsSync())
          File(p.join(root, 'pubspec.yaml')),
    ];
  }

  @override
  String get name => 'flutter-assemble';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final cache = StepCache(ctx.buildDir, verbose: ctx.verbose);
    await cache.load();
    final fp = await fingerprintInputsDetailed([
      ...filesUnder(p.join(ctx.projectPath, 'lib'), extension: '.dart'),
      ...filesUnder(p.join(ctx.projectPath, 'packages'), extension: '.dart'),
      // Path deps are compiled into the kernel — a sibling-checkout edit
      // must invalidate the cache (pub-workspace layout included).
      ...pathDependencyInputs(ctx.projectPath),
      if (File('${ctx.projectPath}/pubspec.yaml').existsSync())
        '${ctx.projectPath}/pubspec.yaml',
      if (File('${ctx.projectPath}/pubspec.lock').existsSync())
        '${ctx.projectPath}/pubspec.lock',
      if (File('${ctx.projectPath}/.dart_tool/package_config.json')
          .existsSync())
        '${ctx.projectPath}/.dart_tool/package_config.json',
    ], extras: [
      'entrypoint:${ctx.entrypoint}',
      'mode:${ctx.mode.name}',
      'abis:${state.abis.join(',')}',
      'defines:${(ctx.dartDefines.entries.toList()..sort((final a, final b) => a.key.compareTo(b.key))).map((final e) => '${e.key}=${e.value}').join(',')}',
      'buildArgs:${ctx.config.flutter.buildArgs.join(',')}',
      'probe:${ctx.config.flutter.startupProbe}',
    ]);
    final assembleDigests = fp.fileDigests;
    final cached = cache.hit('flutter-assemble', fp.digest);
    if (cached != null) {
      print('🎨 flutter assemble: unchanged inputs — reusing artifacts');
      state.flutterAssetsDir = cached['flutter_assets_dir'] as String;
      state.addProvenanceFact(
        ProvenanceFact(factAssembleFingerprint, fp.digest),
      );
      return StepResult.success();
    }

    // Freshness check: `flutter assemble` (unlike `flutter build`) never runs
    // pub get implicitly; a stale package_config desynchronizes the kernel
    // compile from pubspec. Re-sync when pubspec is newer than the config.
    final packageConfig = packageConfigFor(ctx.projectPath);
    final pubspec = File(p.join(ctx.projectPath, 'pubspec.yaml'));
    // Staleness = own pubspec OR any path-dependency's pubspec newer than the
    // generated package_config (sibling checkouts change without touching
    // this project — bare `flutter assemble` never re-syncs on its own).
    final pathDepPubspecs = _pathDependencyPubspecs(ctx.projectPath);
    final configTime = packageConfig != null && packageConfig.existsSync()
        ? packageConfig.lastModifiedSync()
        : DateTime.fromMillisecondsSinceEpoch(0);
    final stale = packageConfig == null ||
        !packageConfig.existsSync() ||
        (pubspec.existsSync() &&
            pubspec.lastModifiedSync().isAfter(configTime)) ||
        pathDepPubspecs.any(
          (final f) => f.existsSync() && f.lastModifiedSync().isAfter(configTime),
        );
    if (stale) {
      print('📦 package_config stale — running flutter pub get...');
      final pubGet = await Process.run(
        'flutter',
        const ['pub', 'get'],
        workingDirectory: ctx.projectPath,
      );
      if (pubGet.exitCode != 0) {
        return StepResult.failure(
          'flutter pub get failed:\n${pubGet.stderr}',
        );
      }
    }

    print('🎨 Running flutter assemble...');
    // ADR-0007 AUTO: the flutter tool subprocess resolves the Android SDK on
    // its own (env → project android/local.properties). Projects with a
    // stale/missing sdk.dir fail build_hooks even though oka found the SDK —
    // pass the located SDK through the environment so `flutter assemble` sees
    // exactly what oka's own steps see.
    final androidSdkHome = await _locateAndroidSdkSafe(state);
    final sdkEnv = androidSdkHome == null
        ? null
        : {'ANDROID_SDK_ROOT': androidSdkHome, 'ANDROID_HOME': androidSdkHome};
    // ADR-0029 D7: compile the generated beacon wrapper instead of the raw
    // entrypoint so the verify ladder can prove Dart main() ran.
    final effectiveEntrypoint = ctx.config.flutter.startupProbe
        ? generateStartupBeaconEntrypoint(
            projectPath: ctx.projectPath,
            entrypoint: ctx.entrypoint,
            buildDir: ctx.buildDir,
          )
        : ctx.entrypoint;
    final assembleOut = p.join(ctx.buildDir, 'assemble');
    final assembleResult = await assembler.assembleApplication(
      projectPath: ctx.projectPath,
      outputDir: assembleOut,
      entrypoint: effectiveEntrypoint,
      mode: ctx.mode,
      primaryAbi: state.abis.first,
      extraArgs: ctx.config.flutter.buildArgs,
      dartDefines: ctx.dartDefines,
      environment: sdkEnv,
    );
    if (!assembleResult.success) {
      return StepResult.failure(
        'flutter assemble failed (exit ${assembleResult.exitCode}):\n'
        '${assembleResult.stderr}\n${assembleResult.stdout}',
      );
    }
    final assetsDir =
        assembleResult.flutterAssetsDir ??
        await findFlutterAssetsDir(assembleOut);
    if (assetsDir == null) {
      return StepResult.failure(
        'flutter_assets not found under assemble output: $assembleOut',
      );
    }
    state.flutterAssetsDir = assetsDir;
    state.addProvenanceFact(
      ProvenanceFact(factAssembleFingerprint, fp.digest),
    );
    await cache.store('flutter-assemble', fp.digest, {
      'flutter_assets_dir': assetsDir,
    }, inputDigests: assembleDigests);
    return StepResult.success();
  }
}

/// Extracts libflutter.so per ABI from the Flutter engine artifacts.
///
/// The engine variant always matches the build mode (debug → debug engine,
/// profile → profile engine, release → release engine). A missing variant
/// jar triggers `flutter precache --android` once; if it is still missing
/// the build fails — substituting another variant's engine (e.g. the debug
/// JIT engine under a release AOT snapshot) ships apps that hang on the
/// splash screen and never run Dart `main()`.
///
/// ADR-0028: the step is fingerprinted (engine jar identity + variant +
/// ABIs) so an unchanged engine skips re-extraction, and its outputs are
/// store entries keyed by the jar identity — a second project materializes
/// them as block-sharing links instead of re-extracting.
class EngineExtractionStep extends BuildStep {

  EngineExtractionStep({this.toolchain, final LocalArtifactStore? store})
    : store = store ?? LocalArtifactStore();
  @override
  Set<Artifact<Object>> get requires => {abis};

  @override
  Set<Artifact<Object>> get provides => {libflutterByAbi, embeddingJar};

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T1).
  final ResolvedToolchain? toolchain;

  /// Store for the extracted engine artifacts (injectable for tests).
  final LocalArtifactStore store;

  /// Bump when extraction output changes identity (names, jar filtering).
  static const _extractorVersion = 'v2';

  @override
  String get name => 'engine-extraction';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    print('📦 Extracting Flutter engine natives...');
    final engine = await engineArtifacts(
      ctx,
      toolchain ?? state.resolvedToolchain ?? ResolvedToolchain(),
    );
    final variant = engineVariantForMode(ctx.mode);
    final Map<String, String> jarsByAbi;
    try {
      jarsByAbi = await engine.ensureEngineJars(
        abis: state.abis,
        variant: variant,
        workingDirectory: ctx.projectPath,
        log: print,
      );
    } on Exception catch (e) {
      return StepResult.failure('engine artifacts unavailable: $e');
    }
    final libDir = p.join(ctx.buildDir, 'lib');
    final embeddingJarDest = p.join(ctx.buildDir, 'flutter_embedding_classes.jar');
    String soDestFor(final String abi) =>
        p.join(libDir, normalizeAbi(abi), 'libflutter.so');

    final cache = StepCache(ctx.buildDir, verbose: ctx.verbose);
    await cache.load();
    final fp = await fingerprintInputs(jarsByAbi.values.toList(), extras: [
      'extractor:$_extractorVersion',
      'variant:$variant',
      'abis:${state.abis.map(normalizeAbi).join(',')}',
    ]);
    final cached = cache.hit('engine-extraction', fp, requiredOutputs: [
      for (final abi in state.abis) soDestFor(abi),
      embeddingJarDest,
    ]);
    if (cached != null) {
      print('🧩 engine artifacts: unchanged engine — reusing extracted outputs');
      state.libflutterByAbi = {
        for (final abi in state.abis) normalizeAbi(abi): soDestFor(abi),
      };
      state.embeddingJar = embeddingJarDest;
      // ADR-0029 D1: cached runs still attest — provenance must not depend
      // on whether the step body executed.
      state.addProvenanceFact(
        ProvenanceFact(factEngineVariant, variant),
      );
      state.addProvenanceFact(
        ProvenanceFact(
          factEngineLibflutterSha256,
          await fileSha256(soDestFor(state.abis.first)) ?? '',
        ),
      );
      return StepResult.success();
    }

    final identities = <String, String>{};
    for (final entry in jarsByAbi.entries) {
      identities[entry.key] = await _fileSha256(entry.value);
    }

    final libflutterByAbi = <String, String>{};
    for (final entry in jarsByAbi.entries) {
      final abi = normalizeAbi(entry.key);
      final dest = soDestFor(abi);
      await _materializeFromStore(
        key: ContentKey.compute(
          category: 'engine',
          name: 'libflutter',
          version: identities[entry.key]!.substring(0, 12),
          inputs: [
            'flutter-engine-jar:${identities[entry.key]}',
            'variant:$variant',
            'abi:$abi',
            'extractor:$_extractorVersion',
          ],
          platform: abi,
          fileName: 'libflutter.so',
        ),
        produce: () async {
          final tmp = await Directory.systemTemp.createTemp('oka_engine_');
          return File(
            await engine.extractLibflutterFromJar(
              flutterJar: entry.value,
              abi: entry.key,
              destSoPath: p.join(tmp.path, 'libflutter.so'),
            ),
          );
        },
        destination: dest,
        verbose: ctx.verbose,
      );
      libflutterByAbi[abi] = dest;
      if (ctx.verbose) {
        print('   ${entry.key} engine: ${entry.value}');
      }
    }
    state.libflutterByAbi = libflutterByAbi;
    // ADR-0029 D1: record which engine variant and jar the natives came
    // from — the fact that would have caught the 2026-09-27 debug-engine
    // release at packaging time instead of on a device.
    final primaryAbi = normalizeAbi(state.abis.first);
    state.addProvenanceFact(
      ProvenanceFact(factEngineVariant, variant),
    );
    state.addProvenanceFact(
      ProvenanceFact(
        factEngineJarSha256,
        await fileSha256(jarsByAbi[primaryAbi]!) ?? '',
      ),
    );
    state.addProvenanceFact(
      ProvenanceFact(
        factEngineLibflutterSha256,
        await fileSha256(libflutterByAbi[primaryAbi]!) ?? '',
      ),
    );

    // Flutter embedding jar (classes only for javac/d8) — same variant the
    // natives came from.
    final embeddingAbi = normalizeAbi(state.abis.first);
    final embeddingJarFull = jarsByAbi[embeddingAbi];
    if (embeddingJarFull == null) {
      return StepResult.failure(
        'flutter.jar (embedding) not resolved for ${state.abis.first}; '
        'run flutter precache',
      );
    }
    await _materializeFromStore(
      key: ContentKey.compute(
        category: 'engine',
        name: 'flutter-embedding',
        version: identities[embeddingAbi]!.substring(0, 12),
        inputs: [
          'flutter-engine-jar:${identities[embeddingAbi]}',
          'variant:$variant',
          'extractor:$_extractorVersion',
        ],
        platform: 'jvm',
        fileName: 'flutter_embedding_classes.jar',
      ),
      produce: () async {
        final tmp = await Directory.systemTemp.createTemp('oka_engine_');
        return File(
          await engine.extractEmbeddingClassesJar(
            flutterJar: embeddingJarFull,
            destJarPath: p.join(tmp.path, 'flutter_embedding_classes.jar'),
          ),
        );
      },
      destination: embeddingJarDest,
      verbose: ctx.verbose,
    );
    state.embeddingJar = embeddingJarDest;
    await cache.store('engine-extraction', fp, {
      'embedding_jar': embeddingJarDest,
    });
    return StepResult.success();
  }

  /// Store-then-materialize (ADR-0028 §2/§3): a store hit skips [produce]
  /// entirely; the buildDir copy shares blocks via the clonefile → reflink →
  /// hardlink → copy chain. Stored entries are regenerable, so store gc is
  /// always safe.
  Future<void> _materializeFromStore({
    required final ContentKey key,
    required final Future<File> Function() produce,
    required final String destination,
    required final bool verbose,
  }) async {
    final stored = await store.fetch(key, produce);
    final materialization = await materializeFile(
      source: stored.path,
      destination: destination,
    );
    if (verbose) {
      print('   ${materialization.strategy.name} → $destination');
    }
  }

  static Future<String> _fileSha256(final String path) async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }
}

/// Assembles release AOT (libapp.so) per ABI. No-op in debug/profile.
class ReleaseAotStep extends BuildStep {

  ReleaseAotStep({this.toolchain, final FlutterAssembler? assembler})
    : assembler = assembler ?? FlutterAssembler();
    /// Resolves the Android SDK without failing the step.
  Future<String?> _locateAndroidSdkSafe(final PipelineState state) async {
    try {
      return await (toolchain ?? state.resolvedToolchain ??
              ResolvedToolchain())
          .findAndroidSdk();
    } on Exception {
      return null;
    }
  }

@override
  Set<Artifact<Object>> get requires => {abis};

  @override
  Set<Artifact<Object>> get provides => {libappByAbi};

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T1).
  final ResolvedToolchain? toolchain;
  final FlutterAssembler assembler;

  @override
  String get name => 'release-aot';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    if (!ctx.mode.isRelease) return StepResult.success();

    final cache = StepCache(ctx.buildDir, verbose: ctx.verbose);
    await cache.load();
    final aotFp = await fingerprintInputsDetailed([
      ...filesUnder(p.join(ctx.projectPath, 'lib'), extension: '.dart'),
      ...filesUnder(p.join(ctx.projectPath, 'packages'), extension: '.dart'),
      // Path deps are compiled into the AOT snapshot — a sibling-checkout
      // edit must invalidate the cache (pub-workspace layout included).
      ...pathDependencyInputs(ctx.projectPath),
      if (File('${ctx.projectPath}/pubspec.lock').existsSync())
        '${ctx.projectPath}/pubspec.lock',
      if (File('${ctx.projectPath}/.dart_tool/package_config.json')
          .existsSync())
        '${ctx.projectPath}/.dart_tool/package_config.json',
    ], extras: [
      'entrypoint:${ctx.entrypoint}',
      'abis:${state.abis.join(',')}',
      'defines:${(ctx.dartDefines.entries.toList()..sort((final a, final b) => a.key.compareTo(b.key))).map((final e) => '${e.key}=${e.value}').join(',')}',
      'buildArgs:${ctx.config.flutter.buildArgs.join(',')}',
      'probe:${ctx.config.flutter.startupProbe}',
    ]);
    final aotDigests = aotFp.fileDigests;
    final cachedAot = cache.hit('release-aot', aotFp.digest);
    if (cachedAot != null) {
      print('⚡ release AOT: unchanged inputs — reusing libapp.so');
      state.libappByAbi =
          (cachedAot['libapp_by_abi'] as Map).cast<String, String>();
      // ADR-0029 D1: cached runs still attest.
      final primaryAbi = normalizeAbi(state.abis.first);
      final primaryLibapp = state.libappByAbi[primaryAbi];
      if (primaryLibapp != null) {
        state.addProvenanceFact(
          ProvenanceFact(
            factAotSnapshotSha256,
            await fileSha256(primaryLibapp) ?? '',
          ),
        );
        final buildId = await stagedAotBuildId(state);
        if (buildId != null) {
          state.addProvenanceFact(ProvenanceFact(factAotBuildId, buildId));
        }
      }
      return StepResult.success();
    }

    print('⚡ Assembling release AOT (libapp.so)...');
    final effectiveEntrypoint = ctx.config.flutter.startupProbe
        ? generateStartupBeaconEntrypoint(
            projectPath: ctx.projectPath,
            entrypoint: ctx.entrypoint,
            buildDir: ctx.buildDir,
          )
        : ctx.entrypoint;
    final libappByAbi = <String, String>{};
    for (final abi in state.abis) {
      final aotOut = p.join(ctx.buildDir, 'aot', normalizeAbi(abi));
      final aotSdkEnv = await _locateAndroidSdkSafe(state);
      final aotResult = await assembler.assembleAot(
        projectPath: ctx.projectPath,
        outputDir: aotOut,
        entrypoint: effectiveEntrypoint,
        abi: abi,
        extraArgs: ctx.config.flutter.buildArgs,
        dartDefines: ctx.dartDefines,
            environment: aotSdkEnv == null
          ? null
          : {
              'ANDROID_SDK_ROOT': aotSdkEnv,
              'ANDROID_HOME': aotSdkEnv,
            },
    );
      if (!aotResult.success) {
        return StepResult.failure(
          'flutter AOT assemble failed for $abi: ${aotResult.stderr}',
        );
      }
      final so = await findLibappSo(aotOut);
      if (so == null) {
        return StepResult.failure(
          'libapp.so/app.so not found for ABI $abi in $aotOut',
        );
      }
      final dest = p.join(ctx.buildDir, 'lib', normalizeAbi(abi), 'libapp.so');
      await File(dest).parent.create(recursive: true);
      await File(so).copy(dest);
      libappByAbi[normalizeAbi(abi)] = dest;
    }
    state.libappByAbi = libappByAbi;
    // ADR-0029 D1: record the snapshot hash + build id — the pairing the
    // engine enforces at startup, checked here instead of on a device.
    final primaryAbi = normalizeAbi(state.abis.first);
    final primaryLibapp = libappByAbi[primaryAbi];
    if (primaryLibapp != null) {
      state.addProvenanceFact(
        ProvenanceFact(
          factAotSnapshotSha256,
          await fileSha256(primaryLibapp) ?? '',
        ),
      );
      final buildId = await stagedAotBuildId(state);
      if (buildId != null) {
        state.addProvenanceFact(ProvenanceFact(factAotBuildId, buildId));
      }
    }
    await cache.store('release-aot', aotFp.digest, {
      'libapp_by_abi': libappByAbi,
    }, inputDigests: aotDigests);
    return StepResult.success();
  }
}

/// Resolves the AndroidX runtime dependency set (extensible via
/// `pipeline.extra_deps` in oka.yaml and [PipelineState.extraRuntimeJars]).
class DependencyResolveStep extends BuildStep {

  DependencyResolveStep({final DependencyCache? cache})
    : cache = cache ?? DependencyCache();
  @override
  Set<Artifact<Object>> get provides => {androidxJars};

  final DependencyCache cache;

  @override
  String get name => 'dependency-resolve';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    print('📚 Resolving AndroidX dependencies...');
    List<ResolvedJar> jars;
    try {
      jars = await cache.resolveFlutterAndroidX();
    } on Exception catch (e) {
      // Best-effort: compile may still succeed with cached JARs.
      print('⚠️  AndroidX resolve incomplete: $e');
      print('   Compile may fail without cached JARs from the oka artifact store');
      jars = [];
    }

    // Merge plugin natives into lib/ while we hold plugin outputs.
    final packaged = state.packagedPlugins;
    if (packaged != null) {
      final libDir = p.join(ctx.buildDir, 'lib');
      for (final entry in packaged.nativeLibsByAbi.entries) {
        final abi = normalizeAbi(entry.key);
        for (final so in entry.value) {
          final dest = p.join(libDir, abi, p.basename(so));
          await File(dest).parent.create(recursive: true);
          await File(so).copy(dest);
          if (ctx.verbose) print('   packaged native: $dest');
        }
      }
    }

    state.androidxJars = jars;
    // ADR-0029 D1: the resolution the kernel/AOT was compiled against. A
    // snapshot compiled against an inconsistent resolution is the "VM
    // snapshot invalid" crash class — recording it makes that diagnosable
    // from the artifact.
    final packageConfig = packageConfigFor(ctx.projectPath);
    if (packageConfig != null) {
      state.addProvenanceFact(
        ProvenanceFact(
          factResolutionPackageConfigSha256,
          await fileSha256(packageConfig.path) ?? '',
        ),
      );
    }
    final lock = File(p.join(ctx.projectPath, 'pubspec.lock'));
    if (lock.existsSync()) {
      state.addProvenanceFact(
        ProvenanceFact(
          factResolutionPubspecLockSha256,
          await fileSha256(lock.path) ?? '',
        ),
      );
    }
    return StepResult.success();
  }
}
