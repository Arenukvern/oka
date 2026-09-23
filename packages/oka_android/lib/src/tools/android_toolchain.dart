import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../build/r8_tool.dart' show findR8Jar, kR8Version;
import 'android_tool_policy.dart';
import 'tool_host.dart';

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
    this.processRunner = runToolProcess,
  }) : _env = env ?? ToolchainEnv.platform();

  /// Explicitly configured Android SDK path (config source, hard boundary:
  /// a missing configured path must not silently fall through).
  final String? androidSdkPath;

  /// Explicitly configured Flutter SDK path.
  final String? flutterSdkPath;

  final bool verbose;
  final ToolchainEnv _env;
  final ToolProcessRunner processRunner;

  final Map<String, ToolResolution> _cache = {};

  // -- Policy: ordered candidate sources per tool ---------------------------

  /// Candidate sources for the Android SDK root, most preferred first.
  /// Mirrors the historical `SdkLocator.findAndroidSdk` precedence exactly.
  AndroidToolPolicy get sourcePolicy => AndroidToolPolicy(
    hasConfiguredAndroidSdk: androidSdkPath != null,
    hasConfiguredFlutterSdk: flutterSdkPath != null,
  );

  List<ToolSource> get androidSdkPolicy => sourcePolicy.androidSdkSources;

  @override
  List<ToolSource> describe(final ToolQuery query) =>
      sourcePolicy.describe(query.name);

  String remediationFor(final String tool) => sourcePolicy.remediation(tool);

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
            if (Platform.isWindows) 'cmdline-tools/latest/bin/avdmanager.bat',
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
        found = ResolvedTool(name: 'android-sdk', path: okaSdkEnv, source: src);
      }
    }

    // 3. Oka-managed install root — preferred only when it has packaging
    // tools (build-tools/ present).
    final home = _env.home;
    final okaManaged = home.isEmpty
        ? null
        : p.join(home, '.oka', 'android-sdk');
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
      return ToolResolution(tried: tried, problem: 'Android SDK not found.');
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
        final result = await processRunner('flutter', [
          '--version',
          '--machine',
        ], environment: _env.values);
        if (result.exitCode == 0) {
          final flutterBin = await processRunner('which', [
            'flutter',
          ], environment: _env.values);
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
      ToolSource(sdk.source.kind, '${sdk.source.label} → build-tools (latest)'),
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
      problem:
          'build-tools directory not found in Android SDK'
          '${_buildToolsVersionsEmptyHint(sdk.path)}',
    );
  }

  String _buildToolsVersionsEmptyHint(final String sdkPath) =>
      ' (sdk: $sdkPath)';

  // r8 (optional; jar fallback) ----------------------------------------------

  Future<ToolResolution> _resolveR8() async {
    // oka-managed R8 first (ADR-0013): the Google Maven jar provisioned by
    // `oka get r8` / build self-heal. R8 does not ship in build-tools — the
    // SDK candidates below only match AGP-style layouts.
    final managedR8 = await findR8Jar(
      environment: _env.values,
      home: _env.home,
    );
    if (managedR8 != null) {
      return ToolResolution(
        tool: ResolvedTool(
          name: 'r8',
          path: managedR8,
          version: kR8Version,
          source: const ToolSource(ToolSourceKind.managed, '~/.oka/tools/r8'),
        ),
      );
    }

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
        final r8JarPath = p.join(
          sdkPath,
          'build-tools',
          version,
          'lib',
          'r8.jar',
        );
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
    final cmdlineToolsR8 = p.join(
      sdkPath,
      'cmdline-tools',
      'latest',
      'lib',
      'r8.jar',
    );
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
      if (await File(toolPath).exists() || await Directory(toolPath).exists()) {
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
    const managedSrc = ToolSource(
      ToolSourceKind.managed,
      '~/.oka/tools/kotlin-*/bin',
    );
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
      const pathSrc = ToolSource(ToolSourceKind.system, 'PATH (which kotlinc)');
      tried.add(pathSrc);
      try {
        final result = await processRunner('which', [
          'kotlinc',
        ], environment: _env.values);
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
          found = ResolvedTool(name: 'kotlinc', path: kotlincPath, source: src);
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
    const pathSrc = ToolSource(ToolSourceKind.system, 'PATH (which javac)');
    tried.add(pathSrc);
    try {
      final result = await processRunner('which', [
        'javac',
      ], environment: _env.values);
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
          found = ResolvedTool(name: 'javac', path: javacPath, source: src);
        }
      }
    }

    if (found == null) {
      return ToolResolution(tried: tried, problem: 'javac not found.');
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
      p.join(
        sdkPath,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'android-x64',
        'flutter.jar',
      ),
      p.join(
        sdkPath,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'android-arm',
        'flutter.jar',
      ),
      p.join(
        sdkPath,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'android-arm64',
        'flutter.jar',
      ),
      p.join(
        sdkPath,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'android',
        'flutter.jar',
      ),
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
