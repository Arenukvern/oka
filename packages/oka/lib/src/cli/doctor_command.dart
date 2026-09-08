import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../version.dart';

/// Recursively converts YamlMap/YamlList to Map/List
dynamic _yamlToJson(final Object? value) {
  if (value is YamlMap) {
    return value.map(
      (final k, final v) => MapEntry(k.toString(), _yamlToJson(v)),
    );
  } else if (value is YamlList) {
    return value.map(_yamlToJson).toList();
  }
  return value;
}

/// Doctor command to check system requirements
class DoctorCommand {
  Future<void> run(List<String> args) async {
    print('🔍 Oka Doctor - Checking system configuration...\n');

    final okaVersion = getOkaVersion();
    print('[Oka Version]');
    print('  ℹ️  Oka v$okaVersion');
    print('');

    // ── Toolchain policy (ADR-0013 T1) ────────────────────────────────
    // Resolution as data: ordered candidate sources per tool, evaluated
    // with results + candidates tried. Owned by the T1 toolchain
    // migration — keep edits inside this marked block.
    print('[Toolchain Policy (ADR-0013)]');
    final policyToolchain = ResolvedToolchain();
    for (final line in await policyToolchain.describePolicyLines()) {
      print('  $line');
    }
    print('');
    // ── End toolchain policy block ──────────────────────────────

    // ── Secret audit (ADR-0014 P0) ─────────────────────────────
    // Parse-and-delegate only: the audit mechanics (secret-ish key
    // patterns, tier-rule message) live in oka_core; this block parses
    // the same define flags `oka build` accepts and formats the returned
    // lines. The [Toolchain Policy] block above stays byte-identical.
    final inlineDefineArgs = <String>[
      for (final arg in args)
        if (arg.startsWith('--dart-define='))
          arg.substring('--dart-define='.length),
    ];
    final defineFilePaths = <String>[
      for (final arg in args)
        if (arg.startsWith('--dart-define-from-file='))
          arg.substring('--dart-define-from-file='.length),
    ];
    print('[Secret Audit (ADR-0014)]');
    for (final line in doctorSecretAuditLines(
      inlineDefineArgs: inlineDefineArgs,
      defineFilePaths: defineFilePaths,
    )) {
      print('  $line');
    }
    print('');
    // ── End secret audit block ─────────────────────────────────

    // ── Credential policy (ADR-0014 P0) ────────────────────────
    // Parse-and-delegate only: ordered credential-path policy, OKA_* env
    // discovery, and repo hygiene live in oka_core.
    print('[Credential Policy (ADR-0014)]');
    for (final line in doctorCredentialPolicyLines(
      projectPath: Directory.current.path,
    )) {
      print('  $line');
    }
    print('');
    // ── End credential policy block ───────────────────────────────

    final locator = SdkLocator();
    var allGood = true;

    // Load oka.yaml if it exists for version requirements
    OkaConfig? config;
    final okaYamlFile = File('oka.yaml');
    if (await okaYamlFile.exists()) {
      try {
        final okaYamlContent = await okaYamlFile.readAsString();
        final okaYamlData = loadYaml(okaYamlContent);
        config = OkaConfig.fromJson(_yamlToJson(okaYamlData));
      } catch (e) {
        // Failed to parse config
      }
    }

    // Check Flutter SDK
    print('[Flutter SDK]');
    try {
      final flutterSdk = await locator.findFlutterSdk();
      print('  ✅ Found at: $flutterSdk');

      // Check Flutter version
      final result = await Process.run('flutter', ['--version']);
      if (result.exitCode == 0) {
        final version = (result.stdout as String).split('\n')[0];
        print('  ℹ️  $version');
      }
    } catch (e) {
      print('  ❌ Not found: $e');
      allGood = false;
    }
    print('');

    // Check Android SDK (ADR-0015: the check mechanics live in oka_android;
    // the command formats the returned check results).
    print('[Android SDK]');
    final sdkReport = await androidSdkDoctorChecks(toolchain: locator);
    if (sdkReport.sdkFound) {
      print('  ✅ Found at: ${sdkReport.sdkPath}');

      // Required packaging tools
      for (final check in sdkReport.toolChecks) {
        if (check.found) {
          print('  ✅ ${check.tool}: ${p.basename(p.dirname(check.path!))}');
        } else {
          print('  ❌ ${check.tool}: Not found');
          allGood = false;
        }
      }

      // Check R8 separately (it's optional but recommended)
      final r8Path = sdkReport.r8Path;
      if (r8Path != null) {
        print('  ✅ r8: ${p.basename(p.dirname(r8Path))}');
      } else {
        print(
          '  ⚠️  r8: Not found (optional, but recommended for release builds)',
        );
        print('      💡 Run "oka get r8" to install');
      }
    } else {
      print('  ❌ Not found: ${sdkReport.sdkError}');
      allGood = false;
    }
    print('');

    // Check Java
    print('[Java Development Kit]');
    try {
      await locator.findJavac();
      print('  ✅ javac found');

      final result = await Process.run('java', ['-version']);
      if (result.exitCode == 0) {
        final versionOutput = (result.stderr as String).split('\n')[0];
        print('  ℹ️  $versionOutput');

        // Extract major version
        final versionMatch = RegExp(
          r'version "(\d+)\.?(\d*)\.?(\d*)[_\-]?.*?"',
        ).firstMatch(versionOutput);

        if (versionMatch != null) {
          final major = versionMatch.group(1)!;
          final currentMajor = major == '1' ? versionMatch.group(2)! : major;

          // Check if there's a required version in oka.yaml
          if (config != null) {
            final requiredVersion = config.android.requiredJavaVersion;
            final kotlinVersion = config.android.kotlinVersion;

            if (requiredVersion != null) {
              print('  ℹ️  Required by oka.yaml: Java $requiredVersion');

              try {
                final currentInt = int.parse(currentMajor);
                final requiredInt = int.parse(requiredVersion);

                if (currentInt > requiredInt) {
                  print(
                    '  ⚠️  Warning: Current Java ($currentMajor) is newer than required ($requiredVersion)',
                  );
                  if (kotlinVersion != null) {
                    print('     Kotlin $kotlinVersion may not be compatible');
                  }
                } else if (currentInt == requiredInt) {
                  print('  ✓ Java version matches requirements');
                }
              } catch (e) {
                // Could not parse versions
              }
            }

            if (kotlinVersion != null) {
              print('  ℹ️  Kotlin version: $kotlinVersion');
            }
          }
        }
      }
    } catch (e) {
      print('  ❌ Not found: $e');
      print('  💡 Install JDK 11 or later');
      allGood = false;
    }

    // Check version managers
    print('');
    print('[Java Version Managers]');
    final versionManager = await VersionManager.detectBestVersionManager();
    if (versionManager != null) {
      print('  ✅ ${versionManager.name} detected');

      final installedVersions = await versionManager
          .listInstalledJavaVersions();
      if (installedVersions.isNotEmpty) {
        print('  ℹ️  Installed Java versions:');
        for (final version in installedVersions.take(5)) {
          print('     - $version');
        }
        if (installedVersions.length > 5) {
          print('     ... and ${installedVersions.length - 5} more');
        }
      }
    } else {
      print('  ⚠️  No version manager detected');
      print(
        '     Consider installing SDKMAN! (Linux/macOS) or using winget (Windows)',
      );
      print('     This allows automatic Java version switching');
    }
    print('');

    // Check Kotlin (optional)
    print('[Kotlin Compiler (optional)]');
    try {
      final kotlinc = await locator.findKotlinc();
      if (kotlinc != null) {
        print('  ✅ kotlinc found');

        final result = await Process.run('kotlinc', ['-version']);
        if (result.exitCode == 0) {
          print('  ℹ️  ${result.stdout}');
        }
      } else {
        print('  ⚠️  Not found (will be downloaded if needed)');
      }
    } catch (e) {
      print('  ⚠️  Not found (will be downloaded if needed)');
    }
    print('');

    // Check AI configuration
    print('[AI Agent]');
    final geminiKey = Platform.environment['GEMINI_API_KEY'];
    if (geminiKey != null && geminiKey.isNotEmpty) {
      print('  ✅ GEMINI_API_KEY is set');
    } else {
      print('  ⚠️  GEMINI_API_KEY not set');
      print('  💡 Set GEMINI_API_KEY for Gradle conversion');
      print('  💡 Get API key from: https://makersuite.google.com/app/apikey');
    }

    if (Platform.isMacOS) {
      print(
        '  ℹ️  Running on macOS - Foundation Models will be used when available',
      );
    }
    print('');

    // Check oka.yaml / Dart pipeline (ADR-0010: full-Dart projects have no
    // oka.yaml — a discovered entrypoint is equally valid configuration).
    print('[Project Configuration]');
    final okaYaml = File('oka.yaml');
    if (await okaYaml.exists()) {
      print('  ✅ oka.yaml found');
    } else if (await findPipelineEntrypoint(Directory.current.path) != null) {
      print('  ✅ Dart pipeline entrypoint found (full-Dart config, ADR-0010)');
    } else {
      print('  ⚠️  oka.yaml not found');
      print('  💡 Run "oka init" to create it');
    }
    print('');

    // ── Dev-loop readiness (ADR-0011 H5) ────────────────────────
    // Parse-and-delegate only: the checks (session manifest present,
    // recorded-SDK flutter binary, device ready) live in oka_android's
    // dev layer; this block formats the returned lines. Device absence
    // is advisory (⚠️) — only blocking (environment) failures count
    // toward the summary below.
    print('[Dev Loop (ADR-0011)]');
    final devLoop = await devLoopDoctorChecks(
      projectPath: Directory.current.path,
      toolchain: locator,
    );
    devLoop.lines.forEach(print);
    if (!devLoop.blocking) {
      print(
        '  ℹ️  Run `oka dev` to start the hot-reload attach session '
        '(docs: docs/guides/hot_reload_plan.md)',
      );
    }
    print('');
    // ── End dev-loop readiness block ─────────────────────────────

    // ADR-0007: incremental + self-resolution state
    print('[Build Health (ADR-0007)]');

    // Kotlin compiler (auto-install available)
    try {
      final kotlinc = await locator.findKotlinc();
      print(
        kotlinc != null
            ? '  ✅ kotlinc: $kotlinc'
            : '  ⚠️  kotlinc not found — builds auto-install on demand\n'
                  '     💡 Pre-install: "oka get kotlin"',
      );
    } catch (_) {
      print('  ⚠️  kotlinc not found — builds auto-install on demand');
    }

    // AAB verification dependency (ADR-0004) — the strings live with the
    // mechanism in oka_android (ADR-0015: verbs never know platforms).
    (await bundletoolHealthLines()).forEach(print);

    // Maven cache state
    final mavenCache = Directory(
      p.join(
        Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '.',
        '.oka',
        'cache',
        'maven',
      ),
    );
    if (mavenCache.existsSync()) {
      final artifacts = mavenCache
          .listSync(recursive: true)
          .whereType<File>()
          .length;
      print('  ✅ maven cache: $artifacts artifacts');
    } else {
      print('  ℹ️  maven cache empty — first build will download dependencies');
    }

    // Incremental step cache + package_config staleness
    final stepCache = File('.oka_cache/build/debug/step_cache.json');
    print(
      stepCache.existsSync()
          ? '  ✅ incremental cache: present (debug)'
          : '  ℹ️  incremental cache: empty — first build is a cold build',
    );
    final packageConfig = File('.dart_tool/package_config.json');
    final pubspec = File('pubspec.yaml');
    if (pubspec.existsSync() &&
        (!packageConfig.existsSync() ||
            pubspec.lastModifiedSync().isAfter(
              packageConfig.lastModifiedSync(),
            ))) {
      print('  ⚠️  package_config.json is stale — build will run pub get');
    } else {
      print('  ✅ package_config.json fresh');
    }
    print('');

    // Summary (advisory-only dev-loop findings never fail it — the
    // blocking failure was already counted above).
    if (allGood) {
      print("✅ All checks passed! You're ready to use Oka.");
    } else {
      print('⚠️  Some checks failed. Please fix the issues above.');
      print('   Run "oka doctor" again after fixing.');
    }
  }
}
