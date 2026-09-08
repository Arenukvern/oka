import 'dart:io';

import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import 'java_environment.dart';

/// Injectable environment for toolchain resolution (ADR-0013).
///
/// Production resolves against [ToolchainEnv.platform]; tests inject a plain
/// map + home so precedence policy is unit-testable with no real machine
/// state.
class ToolchainEnv {
  const ToolchainEnv({required this.values, required this.home});

  factory ToolchainEnv.platform() {
    final env = Platform.environment;
    return ToolchainEnv(
      values: env,
      home: env['HOME'] ?? env['USERPROFILE'] ?? '',
    );
  }

  final Map<String, String> values;
  final String home;

  String? operator [](final String key) => values[key];
}

/// Android tool-resolution policy as data (ADR-0013, T1).
///
/// The policy is an ordered list of [ToolSource] candidates per tool —
/// inspectable via [describe], evaluated by [resolve], printable by doctor,
/// and unit-testable via an injected [ToolchainEnv]. Tool-finding semantics
/// are identical to the pre-ADR `SdkLocator` (same precedence, same
/// latest-build-tools selection, same r8 jar fallback); only the shape
/// changed: result + tried candidates instead of opaque control flow.
///
/// Required tools fail with [ToolchainException] listing every candidate in
/// order plus the remediation. No interactive anything: never reads stdin.
class AndroidToolchain implements Toolchain {
  AndroidToolchain({
    this.androidSdkPath,
    this.flutterSdkPath,
    this.verbose = false,
    final ToolchainEnv? env,
  }) : _env = env ?? ToolchainEnv.platform();

  /// Explicitly configured Android SDK path (config source, hard boundary:
  /// a missing configured path must not silently fall through).
  final String? androidSdkPath;

  /// Explicitly configured Flutter SDK path.
  final String? flutterSdkPath;

  final bool verbose;
  final ToolchainEnv _env;

  final Map<String, ToolResolution> _cache = {};

  // -- Policy: ordered candidate sources per tool ---------------------------

  /// Candidate sources for the Android SDK root, most preferred first.
  /// Mirrors the historical `SdkLocator.findAndroidSdk` precedence exactly.
  List<ToolSource> get androidSdkPolicy => [
        if (androidSdkPath != null)
          const ToolSource(ToolSourceKind.config, 'androidSdkPath'),
        const ToolSource(ToolSourceKind.env, 'OKA_ANDROID_SDK'),
        const ToolSource(ToolSourceKind.managed, '~/.oka/android-sdk'),
        const ToolSource(ToolSourceKind.env, 'ANDROID_HOME'),
        const ToolSource(ToolSourceKind.env, 'ANDROID_SDK_ROOT'),
        const ToolSource(ToolSourceKind.system, '~/Android/Sdk'),
        const ToolSource(ToolSourceKind.system, '~/Library/Android/sdk'),
        const ToolSource(ToolSourceKind.system, '/usr/local/android-sdk'),
      ];

  static const _buildToolsTools = ['aapt2', 'd8', 'zipalign', 'apksigner'];

  @override
  List<ToolSource> describe(final ToolQuery query) {
    final name = query.name;
    if (name == 'android-sdk') return androidSdkPolicy;
    if (name == 'flutter-sdk') {
      return [
        if (flutterSdkPath != null)
          const ToolSource(ToolSourceKind.config, 'flutterSdkPath'),
        const ToolSource(ToolSourceKind.system, 'PATH (which flutter)'),
      ];
    }
    if (_buildToolsTools.contains(name)) {
      // Selected from the resolved SDK's build-tools (latest version dir
      // first) — a version rule over the SDK policy, not a separate source.
      return [
        for (final s in androidSdkPolicy)
          ToolSource(s.kind, '${s.label} → build-tools/<latest>/$name'),
      ];
    }
    if (name == 'r8') {
      return [
        for (final s in androidSdkPolicy)
          ToolSource(
            s.kind,
            '${s.label} → build-tools/<latest>/{r8,lib/r8.jar}',
          ),
        const ToolSource(
          ToolSourceKind.managed,
          'cmdline-tools/latest/lib/r8.jar',
        ),
      ];
    }
    if (name == 'adb') {
      return [
        for (final s in androidSdkPolicy)
          ToolSource(s.kind, '${s.label} → platform-tools/adb'),
      ];
    }
    if (name == 'emulator') {
      return [
        for (final s in androidSdkPolicy)
          ToolSource(s.kind, '${s.label} → emulator/emulator'),
      ];
    }
    if (name == 'avdmanager') {
      return [
        for (final s in androidSdkPolicy)
          ToolSource(
            s.kind,
            '${s.label} → cmdline-tools/latest/bin/avdmanager',
          ),
      ];
    }
    if (name == 'system-images') {
      return [
        for (final s in androidSdkPolicy)
          ToolSource(s.kind, '${s.label} → system-images/'),
      ];
    }
    if (name == 'kotlinc') {
      return [
        const ToolSource(ToolSourceKind.managed, '~/.oka/tools/kotlin-*/bin'),
        const ToolSource(ToolSourceKind.system, 'PATH (which kotlinc)'),
        const ToolSource(ToolSourceKind.env, 'KOTLIN_HOME/bin'),
      ];
    }
    if (name == 'javac') {
      return [
        const ToolSource(ToolSourceKind.system, 'PATH (which javac)'),
        const ToolSource(ToolSourceKind.env, 'JAVA_HOME/bin'),
      ];
    }
    if (name == 'kotlin-stdlib') {
      return [
        const ToolSource(
          ToolSourceKind.managed,
          '<kotlinc home>/lib/kotlin-stdlib*.jar',
        ),
      ];
    }
    if (name == 'flutter-jar') {
      return [
        const ToolSource(
          ToolSourceKind.managed,
          '<flutter sdk>/bin/cache/artifacts/engine/{android-x64,android-arm,android-arm64,android}/flutter.jar',
        ),
      ];
    }
    return const [];
  }

  /// Remediation per tool — the "errors name the fix" half of the policy.
  String remediationFor(final String tool) {
    if (tool == 'android-sdk') {
      return 'Run `oka get android-sdk`, or set OKA_ANDROID_SDK / '
          'ANDROID_HOME / ANDROID_SDK_ROOT to an existing SDK.';
    }
    if (tool == 'flutter-sdk') {
      return 'Ensure Flutter is installed and in PATH.';
    }
    if (tool == 'javac') {
      return 'Install a JDK and set JAVA_HOME (e.g. `oka get jdk`).';
    }
    if (tool == 'kotlinc') {
      return 'Run `oka get kotlin`.';
    }
    if (tool == 'flutter-jar') {
      return 'Run `flutter precache --android` to download engine artifacts.';
    }
    if (tool == 'adb') {
      return 'Install platform-tools (`sdkmanager "platform-tools"`) or run '
          '`oka get android-sdk`.';
    }
    if (tool == 'emulator') {
      return 'Install the emulator (`sdkmanager "emulator"`) or run '
          '`oka get android-sdk`.';
    }
    if (tool == 'avdmanager') {
      return 'Install cmdline-tools (`sdkmanager "cmdline-tools;latest"`) '
          'or run `oka get android-sdk`.';
    }
    if (tool == 'system-images') {
      return 'Install a system image, e.g. '
          '`sdkmanager "system-images;android-34;google_apis;x86_64"`.';
    }
    if (tool == 'r8') {
      return 'Run `oka get r8` to install.';
    }
    if (_buildToolsTools.contains(tool)) {
      return 'Install build-tools (`sdkmanager "build-tools;34.0.0"`) or run '
          '`oka get android-sdk`.';
    }
    return 'Run `oka doctor` for a full environment check.';
  }

  // -- Resolution ------------------------------------------------------------

  @override
  Future<ToolResolution> resolve(final ToolQuery query) async {
    final name = query.name;
    final cached = _cache[name];
    if (cached != null) return cached;
    final ToolResolution r;
    switch (name) {
      case 'android-sdk':
        r = await _resolveAndroidSdk();
      case 'flutter-sdk':
        r = await _resolveFlutterSdk();
      case 'aapt2' || 'd8' || 'zipalign' || 'apksigner':
        r = await _resolveBuildTool(name);
      case 'r8':
        r = await _resolveR8();
      case 'adb':
        r = await _resolveAdb();
      case 'emulator':
        r = await _resolveSdkRelative(
          name: 'emulator',
          relativeCandidates: [
            'emulator/emulator',
            if (Platform.isWindows) 'emulator/emulator.exe',
          ],
          problem: 'emulator binary not found in Android SDK (emulator/)',
        );
      case 'avdmanager':
        r = await _resolveSdkRelative(
          name: 'avdmanager',
          relativeCandidates: [
            'cmdline-tools/latest/bin/avdmanager',
            'tools/bin/avdmanager',
            if (Platform.isWindows)
              'cmdline-tools/latest/bin/avdmanager.bat',
          ],
          problem: 'avdmanager not found in Android SDK cmdline-tools',
        );
      case 'system-images':
        r = await _resolveSdkRelative(
          name: 'system-images',
          relativeCandidates: ['system-images'],
          problem: 'no system-images directory in Android SDK',
        );
      case 'kotlinc':
        r = await _resolveKotlinc();
      case 'javac':
        r = await _resolveJavac();
      case 'kotlin-stdlib':
        r = await _resolveKotlinStdlib();
      case 'flutter-jar':
        r = await _resolveFlutterJar();
      default:
        r = const ToolResolution();
    }
    // Cache only successes (failures re-probe: env/files may change).
    if (r.ok) _cache[name] = r;
    return r;
  }

  /// Resolve a required tool; throws [ToolchainException] naming the fix.
  Future<ResolvedTool> require(final ToolQuery query) async {
    final r = await resolve(query);
    final tool = r.tool;
    if (tool != null) return tool;
    throw ToolchainException(
      tool: query.name,
      tried: r.tried,
      problem: r.problem,
      fix: remediationFor(query.name),
    );
  }

  // android-sdk --------------------------------------------------------------

  Future<ToolResolution> _resolveAndroidSdk() async {
    final tried = <ToolSource>[];
    ResolvedTool? found;

    // 1. Explicit config — a missing configured path must fail loudly, never
    // silently fall through.
    if (androidSdkPath != null) {
      const src = ToolSource(ToolSourceKind.config, 'androidSdkPath');
      tried.add(src);
      if (await Directory(androidSdkPath!).exists()) {
        found = ResolvedTool(
          name: 'android-sdk',
          path: androidSdkPath!,
          source: src,
        );
      } else {
        // Hard boundary: a missing configured path must not silently fall
        // through.
        return ToolResolution(
          tried: tried,
          problem: 'Android SDK not found at configured path: $androidSdkPath',
        );
      }
    }

    // 2. OKA_ANDROID_SDK (oka-first env override).
    final okaSdkEnv = _env['OKA_ANDROID_SDK'];
    if (found == null && okaSdkEnv != null && okaSdkEnv.isNotEmpty) {
      const src = ToolSource(ToolSourceKind.env, 'OKA_ANDROID_SDK');
      tried.add(src);
      if (await Directory(okaSdkEnv).exists()) {
        found = ResolvedTool(
          name: 'android-sdk',
          path: okaSdkEnv,
          source: src,
        );
      }
    }

    // 3. Oka-managed install root — preferred only when it has packaging
    // tools (build-tools/ present).
    final home = _env.home;
    final okaManaged = home.isEmpty ? null : p.join(home, '.oka', 'android-sdk');
    if (found == null && okaManaged != null) {
      const src = ToolSource(ToolSourceKind.managed, '~/.oka/android-sdk');
      tried.add(src);
      if (await Directory(okaManaged).exists() &&
          await Directory(p.join(okaManaged, 'build-tools')).exists()) {
        found = ResolvedTool(
          name: 'android-sdk',
          path: okaManaged,
          source: src,
        );
      }
    }

    // 4–5. Standard env locations.
    for (final envName in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      if (found != null) break;
      final value = _env[envName];
      if (value == null || value.isEmpty) continue;
      final src = ToolSource(ToolSourceKind.env, envName);
      tried.add(src);
      if (await Directory(value).exists()) {
        found = ResolvedTool(name: 'android-sdk', path: value, source: src);
      }
    }

    // 6. Common system locations (oka-managed root retried last, matching
    // the historical common-path list).
    final commonPaths = [
      if (home.isNotEmpty) p.join(home, 'Android', 'Sdk'),
      if (home.isNotEmpty) p.join(home, 'Library', 'Android', 'sdk'),
      '/usr/local/android-sdk',
      ?okaManaged,
    ];
    for (final path in commonPaths) {
      if (found != null) break;
      final src = ToolSource(ToolSourceKind.system, path);
      tried.add(src);
      if (await Directory(path).exists()) {
        found = ResolvedTool(name: 'android-sdk', path: path, source: src);
      }
    }

    if (found == null) {
      return ToolResolution(
        tried: tried,
        problem: 'Android SDK not found.',
      );
    }
    return ToolResolution(tool: found, tried: tried);
  }

  // flutter-sdk --------------------------------------------------------------

  Future<ToolResolution> _resolveFlutterSdk() async {
    final tried = <ToolSource>[];
    ResolvedTool? found;

    if (flutterSdkPath != null) {
      const src = ToolSource(ToolSourceKind.config, 'flutterSdkPath');
      tried.add(src);
      if (await Directory(flutterSdkPath!).exists()) {
        found = ResolvedTool(
          name: 'flutter-sdk',
          path: flutterSdkPath!,
          source: src,
        );
      }
    }

    if (found == null) {
      const src = ToolSource(ToolSourceKind.system, 'PATH (which flutter)');
      tried.add(src);
      // Try to run flutter and derive the SDK root from its binary location.
      try {
        final result = await Process.run(
          'flutter',
          ['--version', '--machine'],
          environment: _env.values,
        );
        if (result.exitCode == 0) {
          final flutterBin = await Process.run(
            'which',
            ['flutter'],
            environment: _env.values,
          );
          if (flutterBin.exitCode == 0) {
            final binPath = (flutterBin.stdout as String).trim();
            final sdkPath = p.dirname(p.dirname(binPath));
            if (await Directory(sdkPath).exists()) {
              found = ResolvedTool(
                name: 'flutter-sdk',
                path: sdkPath,
                source: src,
              );
            }
          }
        }
      } on Exception {
        // Flutter not in PATH
      }
    }

    return ToolResolution(
      tool: found,
      tried: tried,
      problem: found == null
          ? 'Flutter SDK not found. Please ensure Flutter is installed and '
              'in PATH.'
          : null,
    );
  }

  // build-tools tools (latest version dir wins) ------------------------------

  /// Lists build-tools version dirs under [sdkPath], newest first
  /// (reverse-lexicographic, as the locator always did).
  Future<List<String>> _buildToolsVersions(final String sdkPath) async {
    final buildToolsDir = Directory(p.join(sdkPath, 'build-tools'));
    if (!await buildToolsDir.exists()) return const [];
    final versions = await buildToolsDir
        .list()
        .where((final e) => e is Directory)
        .map((final e) => p.basename(e.path))
        .toList();
    versions.sort((final a, final b) => b.compareTo(a));
    return versions;
  }

  Future<ToolResolution> _resolveBuildTool(final String name) async {
    final sdkRes = await resolve(const ToolQuery('android-sdk'));
    if (!sdkRes.ok) {
      // Surface the SDK failure directly: the SDK policy is the tried set.
      return sdkRes;
    }
    final sdk = sdkRes.tool!;
    final tried = <ToolSource>[
      ...sdkRes.tried,
      ToolSource(
        sdk.source.kind,
        '${sdk.source.label} → build-tools (latest)',
      ),
    ];
    for (final version in await _buildToolsVersions(sdk.path)) {
      final toolPath = p.join(sdk.path, 'build-tools', version, name);
      if (await File(toolPath).exists()) {
        return ToolResolution(
          tool: ResolvedTool(
            name: name,
            path: toolPath,
            version: version,
            source: sdk.source,
          ),
          tried: tried,
        );
      }
    }
    return ToolResolution(
      tried: tried,
      problem: 'build-tools directory not found in Android SDK'
          '${_buildToolsVersionsEmptyHint(sdk.path)}',
    );
  }

  String _buildToolsVersionsEmptyHint(final String sdkPath) =>
      ' (sdk: $sdkPath)';

  // r8 (optional; jar fallback) ----------------------------------------------

  Future<ToolResolution> _resolveR8() async {
    final sdk = await resolve(const ToolQuery('android-sdk'));
    if (!sdk.ok) return sdk;
    final tried = <ToolSource>[
      ...sdk.tried,
      ToolSource(
        sdk.tool!.source.kind,
        '${sdk.tool!.source.label} → build-tools (latest)',
      ),
    ];
    final sdkPath = sdk.tool!.path;
    if (await Directory(p.join(sdkPath, 'build-tools')).exists()) {
      for (final version in await _buildToolsVersions(sdkPath)) {
        final r8Path = p.join(sdkPath, 'build-tools', version, 'r8');
        if (await File(r8Path).exists()) {
          return ToolResolution(
            tool: ResolvedTool(
              name: 'r8',
              path: r8Path,
              version: version,
              source: sdk.tool!.source,
            ),
            tried: tried,
          );
        }
        // R8 might be a jar file
        final r8JarPath =
            p.join(sdkPath, 'build-tools', version, 'lib', 'r8.jar');
        if (await File(r8JarPath).exists()) {
          return ToolResolution(
            tool: ResolvedTool(
              name: 'r8',
              path: r8JarPath,
              version: version,
              source: sdk.tool!.source,
            ),
            tried: tried,
          );
        }
      }
    }

    // cmdline-tools location
    final cmdlineToolsR8 =
        p.join(sdkPath, 'cmdline-tools', 'latest', 'lib', 'r8.jar');
    const cmdlineSrc = ToolSource(
      ToolSourceKind.managed,
      'cmdline-tools/latest/lib/r8.jar',
    );
    tried.add(cmdlineSrc);
    if (await File(cmdlineToolsR8).exists()) {
      return ToolResolution(
        tool: ResolvedTool(
          name: 'r8',
          path: cmdlineToolsR8,
          source: cmdlineSrc,
        ),
        tried: tried,
      );
    }

    // Optional tool: not found is a resolution result, not an error.
    return ToolResolution(tried: tried);
  }

  // adb ----------------------------------------------------------------------

  Future<ToolResolution> _resolveAdb() => _resolveSdkRelative(
        name: 'adb',
        relativeCandidates: ['platform-tools/adb'],
        problem: 'adb not found in Android SDK platform-tools',
      );

  /// Generic SDK-root-relative resolution for device tools (adb, emulator,
  /// avdmanager, system-images): resolve the SDK through the policy, then
  /// probe the relative candidates in order. Shares the SDK's tried set so
  /// failures document the whole decision path.
  Future<ToolResolution> _resolveSdkRelative({
    required final String name,
    required final List<String> relativeCandidates,
    required final String problem,
  }) async {
    final sdkRes = await resolve(const ToolQuery('android-sdk'));
    if (!sdkRes.ok) return sdkRes;
    final sdk = sdkRes.tool!;
    final tried = <ToolSource>[
      ...sdkRes.tried,
      for (final rel in relativeCandidates)
        ToolSource(sdk.source.kind, '${sdk.source.label} → $rel'),
    ];
    for (final rel in relativeCandidates) {
      final toolPath = p.join(sdk.path, rel);
      if (await File(toolPath).exists() ||
          await Directory(toolPath).exists()) {
        return ToolResolution(
          tool: ResolvedTool(name: name, path: toolPath, source: sdk.source),
          tried: tried,
        );
      }
    }
    return ToolResolution(tried: tried, problem: problem);
  }

  // kotlinc ------------------------------------------------------------------

  Future<ToolResolution> _resolveKotlinc() async {
    final tried = <ToolSource>[];
    ResolvedTool? found;

    // 1. Oka-managed Kotlin installation (~/.oka/tools/kotlin-*).
    const managedSrc =
        ToolSource(ToolSourceKind.managed, '~/.oka/tools/kotlin-*/bin');
    tried.add(managedSrc);
    final home = _env.home;
    if (home.isNotEmpty) {
      final okaToolsDir = Directory(p.join(home, '.oka', 'tools'));
      if (await okaToolsDir.exists()) {
        await for (final entity in okaToolsDir.list()) {
          if (entity is Directory &&
              p.basename(entity.path).startsWith('kotlin-')) {
            final kotlincPath = p.join(entity.path, 'bin', 'kotlinc');
            if (await File(kotlincPath).exists()) {
              found = ResolvedTool(
                name: 'kotlinc',
                path: kotlincPath,
                source: managedSrc,
              );
              break;
            }
          }
        }
      }
    }

    // 2. PATH
    if (found == null) {
      const pathSrc =
          ToolSource(ToolSourceKind.system, 'PATH (which kotlinc)');
      tried.add(pathSrc);
      try {
        final result = await Process.run(
          'which',
          ['kotlinc'],
          environment: _env.values,
        );
        if (result.exitCode == 0) {
          found = ResolvedTool(
            name: 'kotlinc',
            path: (result.stdout as String).trim(),
            source: pathSrc,
          );
        }
      } on Exception {
        // Not in PATH
      }
    }

    // 3. KOTLIN_HOME
    if (found == null) {
      final kotlinHome = _env['KOTLIN_HOME'];
      if (kotlinHome != null && kotlinHome.isNotEmpty) {
        const src = ToolSource(ToolSourceKind.env, 'KOTLIN_HOME/bin');
        tried.add(src);
        final kotlincPath = p.join(kotlinHome, 'bin', 'kotlinc');
        if (await File(kotlincPath).exists()) {
          found = ResolvedTool(
            name: 'kotlinc',
            path: kotlincPath,
            source: src,
          );
        }
      }
    }

    // Optional tool: null result, no throw.
    return ToolResolution(tool: found, tried: tried);
  }

  // javac --------------------------------------------------------------------

  Future<ToolResolution> _resolveJavac() async {
    final tried = <ToolSource>[];
    ResolvedTool? found;

    // 1. PATH
    const pathSrc =
        ToolSource(ToolSourceKind.system, 'PATH (which javac)');
    tried.add(pathSrc);
    try {
      final result = await Process.run(
        'which',
        ['javac'],
        environment: _env.values,
      );
      if (result.exitCode == 0) {
        found = ResolvedTool(
          name: 'javac',
          path: (result.stdout as String).trim(),
          source: pathSrc,
        );
      }
    } on Exception {
      // Not in PATH
    }

    // 2. JAVA_HOME
    if (found == null) {
      final javaHome = _env['JAVA_HOME'];
      if (javaHome != null && javaHome.isNotEmpty) {
        const src = ToolSource(ToolSourceKind.env, 'JAVA_HOME/bin');
        tried.add(src);
        final javacPath = p.join(javaHome, 'bin', 'javac');
        if (await File(javacPath).exists()) {
          found = ResolvedTool(
            name: 'javac',
            path: javacPath,
            source: src,
          );
        }
      }
    }

    if (found == null) {
      return ToolResolution(
        tried: tried,
        problem: 'javac not found.',
      );
    }
    return ToolResolution(tool: found, tried: tried);
  }

  // kotlin-stdlib (derived from kotlinc) --------------------------------------

  Future<ToolResolution> _resolveKotlinStdlib() async {
    final kotlinc = await resolve(const ToolQuery('kotlinc'));
    if (!kotlinc.ok) return ToolResolution(tried: kotlinc.tried);
    final kotlincPath = kotlinc.tool!.path;
    // kotlinc is typically at: <kotlin-home>/bin/kotlinc
    // stdlib is at: <kotlin-home>/lib/kotlin-stdlib.jar
    final kotlinHome = p.dirname(p.dirname(kotlincPath));
    final libDir = p.join(kotlinHome, 'lib');

    final stdlibPath = p.join(libDir, 'kotlin-stdlib.jar');
    if (await File(stdlibPath).exists()) {
      return ToolResolution(
        tool: ResolvedTool(
          name: 'kotlin-stdlib',
          path: stdlibPath,
          source: kotlinc.tool!.source,
        ),
        tried: kotlinc.tried,
      );
    }

    final libDirectory = Directory(libDir);
    if (await libDirectory.exists()) {
      await for (final entity in libDirectory.list()) {
        if (entity is File &&
            p.basename(entity.path).startsWith('kotlin-stdlib')) {
          return ToolResolution(
            tool: ResolvedTool(
              name: 'kotlin-stdlib',
              path: entity.path,
              source: kotlinc.tool!.source,
            ),
            tried: kotlinc.tried,
          );
        }
      }
    }
    return ToolResolution(tried: kotlinc.tried);
  }

  // flutter-jar --------------------------------------------------------------

  Future<ToolResolution> _resolveFlutterJar() async {
    final flutterSdkRes = await resolve(const ToolQuery('flutter-sdk'));
    if (!flutterSdkRes.ok) return flutterSdkRes;
    final flutterSdk = flutterSdkRes.tool!;
    final sdkPath = flutterSdk.path;
    final tried = <ToolSource>[...flutterSdkRes.tried];
    final possiblePaths = [
      p.join(sdkPath, 'bin', 'cache', 'artifacts', 'engine', 'android-x64',
          'flutter.jar'),
      p.join(sdkPath, 'bin', 'cache', 'artifacts', 'engine', 'android-arm',
          'flutter.jar'),
      p.join(sdkPath, 'bin', 'cache', 'artifacts', 'engine', 'android-arm64',
          'flutter.jar'),
      p.join(sdkPath, 'bin', 'cache', 'artifacts', 'engine', 'android',
          'flutter.jar'),
    ];
    for (final path in possiblePaths) {
      if (await File(path).exists()) {
        return ToolResolution(
          tool: ResolvedTool(
            name: 'flutter-jar',
            path: path,
            source: flutterSdk.source,
          ),
          tried: tried,
        );
      }
    }
    return ToolResolution(
      tried: tried,
      problem: 'Flutter embedding JAR not found.',
    );
  }
}

/// AndroidX JAR provisioning through the shared [ArtifactStore] (ADR-0013).
///
/// Kept as-is from the T0 unification: legacy downloads under
/// `~/.oka/cache/androidx` still resolve (read-only), new downloads land in
/// the store (`OKA_CACHE`-pointable) and are automatic — never interactive,
/// no stdin in the build path. This is provisioning, not resolution: it
/// moves bytes, the policy only points at the result.
class AndroidxJarProvisioner {
  AndroidxJarProvisioner({final ArtifactStore? store})
    : _store = store ?? LocalArtifactStore();
  final ArtifactStore _store;

  /// Locate AndroidX annotation JAR
  Future<String> findAndroidXAnnotations() => _androidXJar(
        name: 'annotation-jvm',
        version: '1.9.1',
        legacyFileName: 'annotation-jvm-1.9.1.jar',
        miss: (final tmpDir) => _downloadAndroidXJar(
          url:
              'https://maven.google.com/androidx/annotation/annotation-jvm/1.9.1/annotation-jvm-1.9.1.jar',
          fileName: 'annotation-jvm-1.9.1.jar',
          tmpDir: tmpDir,
        ),
      );

  /// Locate AndroidX lifecycle-common JAR
  ///
  /// Downloads from Google Maven through the artifact store when missing.
  Future<String> findAndroidXLifecycle() => _androidXJar(
        name: 'lifecycle-common-jvm',
        version: '2.8.7',
        legacyFileName: 'lifecycle-common-jvm-2.8.7.jar',
        miss: (final tmpDir) => _downloadAndroidXJar(
          url:
              'https://maven.google.com/androidx/lifecycle/lifecycle-common-jvm/2.8.7/lifecycle-common-jvm-2.8.7.jar',
          fileName: 'lifecycle-common-jvm-2.8.7.jar',
          tmpDir: tmpDir,
        ),
      );

  /// Locate AndroidX lifecycle-runtime JAR
  ///
  /// Downloads the AAR from Google Maven through the artifact store and
  /// extracts `classes.jar` from it (Android classes ship in AAR packaging).
  Future<String> findAndroidXLifecycleRuntime() => _androidXJar(
        name: 'lifecycle-runtime',
        version: '2.8.7',
        legacyFileName: 'lifecycle-runtime-2.8.7.jar',
        miss: (final tmpDir) async {
          const version = '2.8.7';
          final aarFile = await _downloadAndroidXJar(
            url:
                'https://maven.google.com/androidx/lifecycle/lifecycle-runtime/2.8.7/lifecycle-runtime-2.8.7.aar',
            fileName: 'lifecycle-runtime-$version.aar',
            tmpDir: tmpDir,
          );
          print('   Extracting classes.jar from AAR...');
          final extractResult = await Process.run(
            'unzip',
            ['-j', aarFile.path, 'classes.jar', '-d', tmpDir],
          );
          if (extractResult.exitCode != 0) {
            throw Exception(
                'Failed to extract classes.jar: ${extractResult.stderr}');
          }
          final jarFile = File(p.join(tmpDir, 'classes.jar'))
              .rename(p.join(tmpDir, 'lifecycle-runtime-$version.jar'));
          await aarFile.delete();
          return jarFile;
        },
      );

  /// Resolves an AndroidX JAR: legacy flat cache (`~/.oka/cache/androidx`)
  /// is honored read-only, otherwise the artifact store fetches via [miss]
  /// exactly once and stores under
  /// `<storeRoot>/androidx/<name>/<version>-<hash>/<platform>/`.
  Future<String> _androidXJar({
    required final String name,
    required final String version,
    required final String legacyFileName,
    required final Future<File> Function(String tmpDir) miss,
  }) async {
    final home = Platform.environment['HOME'] ?? '';

    // Legacy cache (pre-store layout) — read-only, still resolves.
    final legacyJar = File(
      p.join(home, '.oka', 'cache', 'androidx', legacyFileName),
    );
    if (await legacyJar.exists()) {
      return legacyJar.path;
    }

    print('📥 Downloading AndroidX $name $version from Google Maven...');
    final key = ContentKey.compute(
      category: 'androidx',
      name: name,
      version: version,
      inputs: ['google-maven:$name:$version'],
    );
    final tmp = await Directory.systemTemp.createTemp('oka_androidx_');
    try {
      final stored = await _store.fetch(key, () => miss(tmp.path));
      print('   File size: ${(await stored.length() / 1024).toStringAsFixed(2)} KB');
      print('✅ Cached at: ${stored.path}');
      return stored.path;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // best-effort temp cleanup
      }
    }
  }

  /// Downloads [url] with curl into [tmpDir]/[fileName], validating the
  /// payload is a real artifact (≥ 1 KB) — partial downloads are removed.
  Future<File> _downloadAndroidXJar({
    required final String url,
    required final String fileName,
    required final String tmpDir,
  }) async {
    final target = File(p.join(tmpDir, fileName));
    print('   URL: $url');
    print('   Target: ${target.path}');

    final result = await Process.run(
      'curl',
      [
        '-L', // Follow redirects
        '-f', // Fail on HTTP errors
        '-o',
        target.path,
        '--progress-bar',
        url,
      ],
      stdoutEncoding: null,
      stderrEncoding: null,
    );

    if (result.exitCode != 0) {
      final stderr = result.stderr != null
          ? String.fromCharCodes(result.stderr as List<int>)
          : 'Unknown error';
      throw Exception('Download failed (exit code ${result.exitCode}): $stderr');
    }

    if (!await target.exists()) {
      throw Exception('Downloaded file not found at: ${target.path}');
    }

    final fileSize = await target.length();
    if (fileSize < 1000) {
      // JAR should be at least 1KB
      await target.delete();
      throw Exception('Downloaded file is too small (possibly invalid)');
    }
    return target;
  }
}

/// The resolved Android toolchain as an injectable artifact (ADR-0013, T1).
///
/// Facade over [AndroidToolchain] (the printable policy) + [AndroidxJarProvisioner]
/// (store-based provisioning). Steps receive this via [PipelineState]
/// (`state.resolvedToolchain`) — no step constructs or calls a god-object.
/// `find*` semantics are identical to the pre-ADR `SdkLocator`.
class ResolvedToolchain implements Toolchain {
  ResolvedToolchain({
    final String? androidSdkPath,
    final String? flutterSdkPath,
    this.verbose = false,
    final ArtifactStore? store,
    final ToolchainEnv? env,
  })  : _toolchain = AndroidToolchain(
          androidSdkPath: androidSdkPath,
          flutterSdkPath: flutterSdkPath,
          verbose: verbose,
          env: env,
        ),
        _androidx = AndroidxJarProvisioner(store: store);

  final AndroidToolchain _toolchain;
  final AndroidxJarProvisioner _androidx;

  /// Whether progress details should be printed.
  final bool verbose;

  /// The underlying policy value (for doctor / tests that want raw
  /// resolution without provisioning).
  AndroidToolchain get policy => _toolchain;

  @override
  List<ToolSource> describe(final ToolQuery query) => _toolchain.describe(query);

  @override
  Future<ToolResolution> resolve(final ToolQuery query) =>
      _toolchain.resolve(query);

  /// Resolve a required tool or throw [ToolchainException] naming the fix.
  Future<ResolvedTool> require(final ToolQuery query) =>
      _toolchain.require(query);

  /// Remediation hint for [tool] (doctor output, error messages).
  String remediationFor(final String tool) => _toolchain.remediationFor(tool);

  // -- find* facade (SdkLocator-compatible semantics) ------------------------

  /// Find Android SDK path. Throws [ToolchainException] on failure.
  Future<String> findAndroidSdk() async =>
      (await require(const ToolQuery('android-sdk'))).path;

  /// Find Flutter SDK path. Throws [ToolchainException] on failure.
  Future<String> findFlutterSdk() async =>
      (await require(const ToolQuery('flutter-sdk'))).path;

  /// Locate aapt2. Throws [ToolchainException] on failure.
  Future<String> findAapt2() async =>
      (await require(const ToolQuery('aapt2'))).path;

  /// Locate d8. Throws [ToolchainException] on failure.
  Future<String> findD8() async => (await require(const ToolQuery('d8'))).path;

  /// Locate r8 (optional: null when not installed).
  Future<String?> findR8() async {
    final r = await resolve(const ToolQuery('r8'));
    return r.tool?.path;
  }

  /// Locate zipalign. Throws [ToolchainException] on failure.
  Future<String> findZipalign() async =>
      (await require(const ToolQuery('zipalign'))).path;

  /// Locate apksigner. Throws [ToolchainException] on failure.
  Future<String> findApksigner() async =>
      (await require(const ToolQuery('apksigner'))).path;

  /// Locate adb. Throws [ToolchainException] on failure.
  Future<String> findAdb() async => (await require(const ToolQuery('adb'))).path;

  /// Locate kotlinc (optional: null when not installed).
  Future<String?> findKotlinc() async {
    final r = await resolve(const ToolQuery('kotlinc'));
    return r.tool?.path;
  }

  /// Find Kotlin standard library JAR (optional: null when unavailable).
  Future<String?> findKotlinStdlib() async {
    final r = await resolve(const ToolQuery('kotlin-stdlib'));
    return r.tool?.path;
  }

  /// Locate javac. Throws [ToolchainException] on failure.
  Future<String> findJavac() async =>
      (await require(const ToolQuery('javac'))).path;

  /// Locate Flutter embedding JAR. Throws [ToolchainException] on failure.
  Future<String> findFlutterJar() async =>
      (await require(const ToolQuery('flutter-jar'))).path;

  /// Locate AndroidX annotation JAR (store-provisioned).
  Future<String> findAndroidXAnnotations() =>
      _androidx.findAndroidXAnnotations();

  /// Locate AndroidX lifecycle-common JAR (store-provisioned).
  Future<String> findAndroidXLifecycle() => _androidx.findAndroidXLifecycle();

  /// Locate AndroidX lifecycle-runtime JAR (store-provisioned).
  Future<String> findAndroidXLifecycleRuntime() =>
      _androidx.findAndroidXLifecycleRuntime();

  // -- Validation ------------------------------------------------------------

  /// Tools required to **package** an APK (no device install).
  ///
  /// Does **not** require `adb` / platform-tools — missing adb must not abort
  /// the no-Gradle build pipeline.
  Future<Map<String, String>> validatePackagingTools() async {
    final tools = <String, String>{};

    tools['android_sdk'] = await findAndroidSdk();
    tools['flutter_sdk'] = await findFlutterSdk();
    tools['aapt2'] = await findAapt2();
    tools['d8'] = await findD8();
    tools['zipalign'] = await findZipalign();
    tools['apksigner'] = await findApksigner();
    tools['javac'] = await findJavac();

    final r8 = await findR8();
    if (r8 != null) {
      tools['r8'] = r8;
    }

    final kotlinc = await findKotlinc();
    if (kotlinc != null) {
      tools['kotlinc'] = kotlinc;
    }

    return tools;
  }

  /// Validate tools for doctor / full environment checks.
  ///
  /// Includes optional `adb` when present; packaging validation is
  /// [validatePackagingTools].
  Future<Map<String, String>> validateTools({final bool requireAdb = false}) async {
    final tools = await validatePackagingTools();

    try {
      tools['adb'] = await findAdb();
    } on Exception {
      if (requireAdb) {
        rethrow;
      }
      // Optional for packaging-only flows
      if (verbose) {
        print('⚠️  adb not found (optional for APK packaging)');
      }
    }

    return tools;
  }

  /// Resolve Java environment for Kotlin compilation
  ///
  /// Reads required Java version from [BuildContext] and ensures
  /// the correct Java version is available for kotlinc
  ///
  /// Returns environment variables map to use for Process.run calls,
  /// or null if system default Java should be used
  Future<Map<String, String>?> resolveJavaForKotlin(final BuildContext ctx) async {
    final requiredJavaVersion = ctx.config.android.requiredJavaVersion;

    final javaEnv = JavaEnvironment(verbose: verbose);

    try {
      final env = await javaEnv.resolveJavaEnvironment(
        requiredJavaVersion,
      );

      return env;
    } catch (e) {
      print('❌ Failed to resolve Java environment: $e');
      rethrow;
    }
  }

  // -- Doctor ----------------------------------------------------------------

  /// One doctor line per tool: `✅ aapt2 → path (source)` or
  /// `❌ tool: not found` + tried candidates + fix. Human- and agent-readable.
  Future<List<String>> describePolicyLines({
    final List<String> tools = defaultDoctorTools,
  }) async {
    final lines = <String>[];
    for (final name in tools) {
      final r = await resolve(ToolQuery(name));
      if (r.ok) {
        final t = r.tool!;
        final version = t.version == null ? '' : ' [${t.version}]';
        lines.add(
          '✅ $name: ${t.path}$version',
        );
        lines.add('   source: ${t.source.qualified}');
      } else {
        lines.add('❌ $name: not found');
        for (var i = 0; i < r.tried.length; i++) {
          lines.add('   tried ${i + 1}: ${r.tried[i].qualified}');
        }
        lines.add('   fix: ${remediationFor(name)}');
      }
    }
    return lines;
  }

  /// Tools the doctor prints the resolved policy for (order matters:
  /// SDK roots first, then tools that derive from them).
  static const defaultDoctorTools = [
    'android-sdk',
    'flutter-sdk',
    'aapt2',
    'd8',
    'r8',
    'zipalign',
    'apksigner',
    'adb',
    'emulator',
    'avdmanager',
    'javac',
    'kotlinc',
  ];
}
