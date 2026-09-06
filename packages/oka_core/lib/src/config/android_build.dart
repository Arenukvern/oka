/// Typed, const-constructible Android base config (ADR-0010).
///
/// The writable counterpart of the `android:` oka.yaml section: identity
/// (package), SDK levels, versions, ABIs, toolchain levels. Everything else
/// (icon, manifest, signing, res dirs, deeplinks, extra deps/assets) is
/// packaging fast-settings and lives in `PipelineOverrides`.
///
/// Precedence: code defaults (empty) < `oka.yaml` < `AndroidBuild` < CLI args.
/// Only fields explicitly set (non-default) are emitted by [toConfigMap], so
/// an `AndroidBuild` can never clobber values it does not carry.
class AndroidBuild {

  const AndroidBuild({
    this.name = '',
    this.packageName = '',
    this.applicationId = '',
    this.compileSdk = '',
    this.targetSdk = '',
    this.minSdk = '',
    this.versionCode = 0,
    this.versionName = '',
    this.sourceDirs = const [],
    this.abis = const [],
    this.javaVersion = 0,
    this.kotlinVersion = '',
    this.requiredJavaVersion = '',
    this.enableOptimization = false,
    this.proguardFiles = const [],
  });
  /// Project display name — feeds the `app_name` string resource and the
  /// activity label fallback (was top-level `name:` in oka.yaml).
  final String name;

  /// Android package name / application id (e.g. `com.example.app`).
  final String packageName;

  /// Overrides the package name in the manifest when non-empty.
  final String applicationId;

  /// Compile/target/min SDK API levels (e.g. `'34'`). Empty → consumer default.
  final String compileSdk;
  final String targetSdk;
  final String minSdk;

  /// Version injected into the manifest. `0`/`''` → pubspec fallback
  /// (ADR-0007) or consumer default.
  final int versionCode;
  final String versionName;

  /// Java/Kotlin source directories (project-relative). Empty → consumer
  /// defaults.
  final List<String> sourceDirs;

  /// Target ABIs. Empty → consumer defaults.
  final List<String> abis;

  /// Java source/target compatibility (0 → 11, matching `AndroidConfig`).
  final int javaVersion;

  /// Kotlin compiler version to pin (empty → auto).
  final String kotlinVersion;

  /// Java runtime version required for kotlinc (empty → system default).
  final String requiredJavaVersion;

  /// ProGuard/R8 optimization toggles.
  final bool enableOptimization;
  final List<String> proguardFiles;

  AndroidBuild copyWith({
    final String? name,
    final String? packageName,
    final String? applicationId,
    final String? compileSdk,
    final String? targetSdk,
    final String? minSdk,
    final int? versionCode,
    final String? versionName,
    final List<String>? sourceDirs,
    final List<String>? abis,
    final int? javaVersion,
    final String? kotlinVersion,
    final String? requiredJavaVersion,
    final bool? enableOptimization,
    final List<String>? proguardFiles,
  }) =>
      AndroidBuild(
        name: name ?? this.name,
        packageName: packageName ?? this.packageName,
        applicationId: applicationId ?? this.applicationId,
        compileSdk: compileSdk ?? this.compileSdk,
        targetSdk: targetSdk ?? this.targetSdk,
        minSdk: minSdk ?? this.minSdk,
        versionCode: versionCode ?? this.versionCode,
        versionName: versionName ?? this.versionName,
        sourceDirs: sourceDirs ?? this.sourceDirs,
        abis: abis ?? this.abis,
        javaVersion: javaVersion ?? this.javaVersion,
        kotlinVersion: kotlinVersion ?? this.kotlinVersion,
        requiredJavaVersion: requiredJavaVersion ?? this.requiredJavaVersion,
        enableOptimization: enableOptimization ?? this.enableOptimization,
        proguardFiles: proguardFiles ?? this.proguardFiles,
      );

  /// Emits the `android:` map — only explicitly set fields — shaped exactly
  /// like the oka.yaml section (the de-facto internal contract consumed via
  /// `AndroidConfig`).
  Map<String, dynamic> toConfigMap() => {
        if (packageName.isNotEmpty) 'package_name': packageName,
        if (applicationId.isNotEmpty) 'application_id': applicationId,
        if (compileSdk.isNotEmpty) 'compile_sdk': compileSdk,
        if (targetSdk.isNotEmpty) 'target_sdk': targetSdk,
        if (minSdk.isNotEmpty) 'min_sdk': minSdk,
        if (versionCode != 0) 'version_code': versionCode,
        if (versionName.isNotEmpty) 'version_name': versionName,
        if (sourceDirs.isNotEmpty) 'source_dirs': sourceDirs,
        if (abis.isNotEmpty) 'abis': abis,
        if (javaVersion != 0) 'java_version': javaVersion,
        if (kotlinVersion.isNotEmpty) 'kotlin_version': kotlinVersion,
        if (requiredJavaVersion.isNotEmpty)
          'required_java_version': requiredJavaVersion,
        if (enableOptimization) 'enable_optimization': enableOptimization,
        if (proguardFiles.isNotEmpty) 'proguard_files': proguardFiles,
      };

  /// A project declaration is meaningless without an identity.
  bool get isEmpty => packageName.isEmpty && toConfigMap().isEmpty;
}

/// Typed, const-constructible Flutter build settings (ADR-0010) — the
/// writable counterpart of the `flutter:` oka.yaml section.
class FlutterBuild {

  const FlutterBuild({
    this.entrypoint = '',
    this.assets = const [],
    this.buildArgs = const [],
    this.buildMode = '',
    this.targetPlatform = '',
    this.treeShakeIcons = false,
    this.enableHotReload = false,
    this.deferredComponents = false,
    this.enginePath = '',
    this.engineVersion = '',
  });
  /// Dart entrypoint (e.g. `lib/main.dart`).
  final String entrypoint;

  /// Asset directories bundled into flutter_assets.
  final List<String> assets;

  /// Extra args forwarded to `flutter assemble`.
  final List<String> buildArgs;

  /// Build mode override (debug/profile/release). Empty → CLI arg.
  final String buildMode;

  /// Target platform (e.g. `android-arm64`). Empty → consumer default.
  final String targetPlatform;

  /// Icon tree-shaking for smaller bundles.
  final bool treeShakeIcons;

  /// Hot-reload friendly debug builds.
  final bool enableHotReload;

  /// Deferred components (dynamic feature delivery).
  final bool deferredComponents;

  /// Custom Flutter engine artifacts path/version (advanced).
  final String enginePath;
  final String engineVersion;

  FlutterBuild copyWith({
    final String? entrypoint,
    final List<String>? assets,
    final List<String>? buildArgs,
    final String? buildMode,
    final String? targetPlatform,
    final bool? treeShakeIcons,
    final bool? enableHotReload,
    final bool? deferredComponents,
    final String? enginePath,
    final String? engineVersion,
  }) =>
      FlutterBuild(
        entrypoint: entrypoint ?? this.entrypoint,
        assets: assets ?? this.assets,
        buildArgs: buildArgs ?? this.buildArgs,
        buildMode: buildMode ?? this.buildMode,
        targetPlatform: targetPlatform ?? this.targetPlatform,
        treeShakeIcons: treeShakeIcons ?? this.treeShakeIcons,
        enableHotReload: enableHotReload ?? this.enableHotReload,
        deferredComponents: deferredComponents ?? this.deferredComponents,
        enginePath: enginePath ?? this.enginePath,
        engineVersion: engineVersion ?? this.engineVersion,
      );

  /// Emits the `flutter:` map — only explicitly set fields — shaped exactly
  /// like the oka.yaml section (consumed via `FlutterConfig`).
  Map<String, dynamic> toConfigMap() => {
        if (entrypoint.isNotEmpty) 'entrypoint': entrypoint,
        if (assets.isNotEmpty) 'assets': assets,
        if (buildArgs.isNotEmpty) 'build_args': buildArgs,
        if (buildMode.isNotEmpty) 'build_mode': buildMode,
        if (targetPlatform.isNotEmpty) 'target_platform': targetPlatform,
        if (treeShakeIcons) 'tree_shake_icons': treeShakeIcons,
        if (enableHotReload) 'enable_hot_reload': enableHotReload,
        if (deferredComponents) 'deferred_components': deferredComponents,
        if (enginePath.isNotEmpty) 'engine_path': enginePath,
        if (engineVersion.isNotEmpty) 'engine_version': engineVersion,
      };
}
