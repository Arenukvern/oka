import 'package:oka_core/oka_core.dart';

import '../build/java_environment.dart';
import '../dependencies/androidx_provisioner.dart';
import 'android_toolchain.dart';
import 'tool_host.dart';

typedef JavaEnvironmentResolver =
    Future<Map<String, String>?> Function(String? requiredVersion);

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
    final ToolProcessRunner processRunner = runToolProcess,
    final AndroidxJarProvisioner? androidxProvisioner,
    JavaEnvironmentResolver? javaEnvironmentResolver,
  }) : _toolchain = AndroidToolchain(
         androidSdkPath: androidSdkPath,
         flutterSdkPath: flutterSdkPath,
         verbose: verbose,
         env: env,
         processRunner: processRunner,
       ),
       _androidx =
           androidxProvisioner ??
           AndroidxJarProvisioner(
             store: store,
             environment: env?.values,
             processRunner: processRunner,
           ),
       _javaEnvironmentResolver =
           javaEnvironmentResolver ??
           ((requiredVersion) =>
               JavaEnvironment().resolveJavaEnvironment(requiredVersion));

  final AndroidToolchain _toolchain;
  final AndroidxJarProvisioner _androidx;
  final JavaEnvironmentResolver _javaEnvironmentResolver;

  /// Whether progress details should be printed.
  final bool verbose;

  /// The underlying policy value (for doctor / tests that want raw
  /// resolution without provisioning).
  AndroidToolchain get policy => _toolchain;

  @override
  List<ToolSource> describe(final ToolQuery query) =>
      _toolchain.describe(query);

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
  Future<String> findAdb() async =>
      (await require(const ToolQuery('adb'))).path;

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
  Future<Map<String, String>> validateTools({
    final bool requireAdb = false,
  }) async {
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
  Future<Map<String, String>?> resolveJavaForKotlin(
    final BuildContext ctx,
  ) async {
    final requiredJavaVersion = ctx.config.android.requiredJavaVersion;

    try {
      final env = await _javaEnvironmentResolver(requiredJavaVersion);

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
        lines.add('✅ $name: ${t.path}$version');
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
