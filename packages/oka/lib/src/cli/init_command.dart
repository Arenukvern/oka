import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Commented scaffold appended to generated oka.yaml: the ADR-0006
/// declarative Dart hook (`pipeline.dart_entrypoint` — the last YAML key oka
/// gains) with a pointer to the full composition example.
const _entrypointScaffold = '''
# Declarative Dart pipeline hook (ADR-0006). Uncomment to own the pipeline in
# Dart instead of YAML fast-settings; the hook composes a typed `Oka` root:
#
# pipeline:
#   dart_entrypoint: tool/oka_pipeline.dart
#
# Or go full-Dart right away (ADR-0010): `oka init --from-yaml` converts this
# file into tool/oka_pipeline.dart.
''';

/// Default Dart pipeline entrypoint location (ADR-0010 discovery convention).
const kDefaultEntrypointPath = 'tool/oka_pipeline.dart';

/// Init command: create oka.yaml from an existing Gradle project, scaffold a
/// fresh project, or convert oka.yaml into a typed Dart pipeline entrypoint
/// (ADR-0010: `--from-yaml`; fresh full-Dart scaffold: `--dart`).
class InitCommand {
  Future<void> run(List<String> args) async {
    print('🚀 Initializing Oka configuration...\n');

    // Check if this is a Flutter project
    final pubspecFile = File('pubspec.yaml');
    if (!await pubspecFile.exists()) {
      print('❌ Not a Flutter project (pubspec.yaml not found)');
      print('   Run this command from the root of a Flutter project');
      exit(1);
    }

    // ADR-0010: convert existing oka.yaml into a typed Dart entrypoint.
    if (args.contains('--from-yaml')) {
      await _convertFromYaml(force: args.contains('--force'));
      return;
    }
    if (args.contains('--yaml')) {
      await _scaffoldYaml(args);
      return;
    }
    // Default (ADR-0010): full-Dart config — no oka.yaml at all.
    await _scaffoldDart(args);
  }

  /// Legacy YAML-first scaffold (opt-in via `oka init --yaml`).
  Future<void> _scaffoldYaml(List<String> args) async {
    // Check if oka.yaml already exists
    final okaYamlFile = File('oka.yaml');
    if (await okaYamlFile.exists()) {
      print('⚠️  oka.yaml already exists');
      if (!_confirmOrCancel('   Overwrite? (y/N): ')) return;
    }

    // Read pubspec.yaml for project info
    final pubspecFile = File('pubspec.yaml');
    final pubspecContent = await pubspecFile.readAsString();
    final pubspec = loadYaml(pubspecContent) as Map<dynamic, dynamic>;
    final projectName = (pubspec['name'] as String?) ?? 'app';
    final projectVersion = (pubspec['version'] as String?) ?? '1.0.0';

    print('📦 Project: $projectName v$projectVersion');

    // Check for existing Gradle configuration
    final gradleFile = File(p.join('android', 'app', 'build.gradle'));

    if (await gradleFile.exists()) {
      // ADR-0012: oka does not embed an LLM. The driving agent (or human)
      // converts the legacy Gradle config in reviewable diff space; oka
      // prints exactly what needs porting and validates the result.
      print('📄 Found android/app/build.gradle (legacy Gradle config).');
      print('');
      print('oka does not parse or auto-convert Gradle (ADR-0012). Convert');
      print('it to oka.yaml by hand or with your coding agent, then re-run');
      print('"oka init --yaml".');
      print('');
      print('What to port from build.gradle / settings.gradle:');
      print('  1. android.package_name  — applicationId / namespace');
      print('  2. android.compile_sdk / min_sdk / target_sdk');
      print('  3. android.version_code / version_name (or rely on pubspec)');
      print('  4. android.abis — splits.abi include lists');
      print('  5. dependencies — each "implementation "g:a:v"" entry');
      print('  6. signing configs — oka signing section (release only)');
      print('');
      print('Validate the result with "oka explain" (plan, no tools run).');
      print(
        'Missing classes after the switch are diagnosed by "oka build apk"',
      );
      print('with a ready-to-paste dependency suggestion.');
      print('');
      print('💡 Creating default oka.yaml instead...');
      await _createDefaultConfig(projectName, projectVersion);
    } else {
      print('📄 No build.gradle found, creating default configuration...\n');
      await _createDefaultConfig(projectName, projectVersion);
    }
  }

  /// ADR-0010: convert an existing oka.yaml into a typed Dart pipeline
  /// entrypoint at [kDefaultEntrypointPath].
  Future<void> _convertFromYaml({bool force = false}) async {
    final okaYamlFile = File('oka.yaml');
    if (!await okaYamlFile.exists()) {
      print('❌ --from-yaml requires an existing oka.yaml to convert');
      exit(1);
    }
    final doc = loadYaml(await okaYamlFile.readAsString());
    if (doc is! Map) {
      print('❌ oka.yaml is not a mapping');
      exit(1);
    }
    await _writeEntrypoint(entrypointFromYaml(doc).code, force: force);
  }

  /// ADR-0010: scaffold a fresh full-Dart pipeline (no oka.yaml).
  Future<void> _scaffoldDart(List<String> args) async {
    final force = args.contains('--force');
    final target = File(p.join('tool', 'oka_pipeline.dart'));
    if (await target.exists() && !force) {
      print('⚠️  $kDefaultEntrypointPath already exists');
      if (!_confirmOrCancel('   Overwrite? (y/N): ')) {
        exit(0);
      }
    }
    final pubspec =
        loadYaml(await File('pubspec.yaml').readAsString())
            as Map<dynamic, dynamic>;
    final name = (pubspec['name'] as String?) ?? 'app';
    final version = (pubspec['version'] as String?) ?? '1.0.0';
    final versionCode = RegExp(r'\+(\d+)$').firstMatch(version)?.group(1);
    final code = entrypointFromYaml({
      'name': name,
      'version': version,
      'android': {
        'package_name': 'com.example.$name',
        if (versionCode != null) 'version_code': int.parse(versionCode),
        'version_name': version,
      },
    }).code;
    await _writeEntrypoint(code);
    print('');
    print('Next steps:');
    print('  1. Edit $kDefaultEntrypointPath — fill in the real package name');
    print('  2. Run "oka explain" to see the validated plan');
    print('  3. Run "oka build apk" to build (no oka.yaml needed)');
  }

  /// Prompts only in interactive terminals; non-TTY contexts (CI, agents)
  /// cancel gracefully with a pointer to `--force`.
  bool _confirmOrCancel(String prompt) {
    if (!stdout.hasTerminal) {
      print('   non-interactive session — pass --force to overwrite');
      return false;
    }
    stdout.write(prompt);
    final response = stdin.readLineSync()?.toLowerCase();
    if (response != 'y' && response != 'yes') {
      print('   Cancelled');
      return false;
    }
    return true;
  }

  Future<void> _writeEntrypoint(String code, {bool force = false}) async {
    final target = File(p.join('tool', 'oka_pipeline.dart'));
    if (await target.exists() && !force) {
      print('⚠️  $kDefaultEntrypointPath already exists');
      if (!_confirmOrCancel('   Overwrite? (y/N): ')) {
        exit(0);
      }
    }
    await target.parent.create(recursive: true);
    await target.writeAsString(code);
    print('✅ Typed Dart pipeline written to $kDefaultEntrypointPath');
    print('   `oka build` discovers it automatically (ADR-0010 convention).');
  }

  Future<void> _createDefaultConfig(String name, String version) async {
    final okaYaml = {
      'name': name,
      'version': version,
      'android': {
        'compile_sdk': '34',
        'min_sdk': '21',
        'target_sdk': '34',
        'package_name': 'com.example.$name',
        'version_code': 1,
        'version_name': version,
        'source_dirs': ['src/main/java', 'src/main/kotlin'],
        'res_dirs': ['src/main/res'],
        'abis': ['arm64-v8a', 'armeabi-v7a'],
      },
      'dependencies': <Map<String, dynamic>>[],
    };

    final okaYamlFile = File('oka.yaml');
    await okaYamlFile.writeAsString(
      '${_toYamlString(okaYaml)}\n$_entrypointScaffold',
    );

    print('✅ Default oka.yaml created!');
    print('');
    print('📋 Please edit oka.yaml to add:');
    print('   - Correct package name');
    print('   - Android dependencies');
    print('   - Build configuration');
  }

  String _toYamlString(Map<String, dynamic> data) {
    final buffer = StringBuffer();
    _writeYaml(buffer, data, 0);
    return buffer.toString();
  }

  void _writeYaml(
    final StringBuffer buffer,
    final Object? data,
    final int indent,
  ) {
    final spaces = '  ' * indent;

    if (data is Map) {
      data.forEach((key, value) {
        if (value is Map || value is List) {
          buffer.writeln('$spaces$key:');
          _writeYaml(buffer, value, indent + 1);
        } else {
          buffer.writeln('$spaces$key: $value');
        }
      });
    } else if (data is List) {
      for (final item in data) {
        if (item is Map) {
          buffer.writeln('$spaces-');
          _writeYaml(buffer, item, indent + 1);
        } else {
          buffer.writeln('$spaces- $item');
        }
      }
    }
  }
}

/// Generates typed Dart pipeline entrypoint code from an oka.yaml document
/// (ADR-0010). Pure — unit-tested; `oka init --from-yaml` writes its output.
///
/// Emits a complete `tool/oka_pipeline.dart` mirroring [doc].
///
/// Surfaces converted 1:1: `android:` base config → [AndroidBuild],
/// `flutter:` → [FlutterBuild], `pipeline:` fast-settings + `android.`
/// icon/res_dirs/manifest → [PipelineOverrides]. Anything unsupported
/// (e.g. `android.signing` secrets, unknown keys) is reported in the
/// returned [OkaInitResult.notices] so projects know what to port by hand.
OkaInitResult entrypointFromYaml(Map<dynamic, dynamic> doc) {
  final notices = <String>[];
  final android = doc['android'];
  final androidMap = android is Map ? android : <dynamic, dynamic>{};
  final flutter = doc['flutter'];
  final flutterMap = flutter is Map ? flutter : <dynamic, dynamic>{};
  final pipeline = doc['pipeline'];
  final pipelineMap = pipeline is Map ? pipeline : <dynamic, dynamic>{};

  // ── AndroidBuild ────────────────────────────────────────────────────
  final androidLines = <String>[];
  if (_yStr(doc['name']).isNotEmpty) {
    androidLines.add("name: '${_esc(_yStr(doc['name']))}'");
  }
  String str(String key) => _yStr(androidMap[key]);
  if (str('package_name').isNotEmpty) {
    androidLines.add("packageName: '${_esc(str('package_name'))}'");
  }
  if (str('application_id').isNotEmpty) {
    androidLines.add("applicationId: '${_esc(str('application_id'))}'");
  }
  for (final entry in {
    'compile_sdk': 'compileSdk',
    'target_sdk': 'targetSdk',
    'min_sdk': 'minSdk',
  }.entries) {
    if (str(entry.key).isNotEmpty) {
      androidLines.add("${entry.value}: '${_esc(str(entry.key))}'");
    }
  }
  final versionCode = androidMap['version_code'];
  if (versionCode is int && versionCode != 0) {
    androidLines.add('versionCode: $versionCode');
  } else if (versionCode is String && int.tryParse(versionCode) != null) {
    androidLines.add('versionCode: $versionCode');
  }
  if (str('version_name').isNotEmpty) {
    androidLines.add("versionName: '${_esc(str('version_name'))}'");
  }
  final sourceDirs = _yStrings(androidMap['source_dirs']);
  if (sourceDirs.isNotEmpty) {
    androidLines.add('sourceDirs: ${_strList(sourceDirs)}');
  }
  final abis = _yStrings(androidMap['abis']);
  if (abis.isNotEmpty) androidLines.add('abis: ${_strList(abis)}');
  final javaVersion = androidMap['java_version'];
  if (javaVersion is int && javaVersion != 0) {
    androidLines.add('javaVersion: $javaVersion');
  }
  if (str('kotlin_version').isNotEmpty) {
    androidLines.add("kotlinVersion: '${_esc(str('kotlin_version'))}'");
  }
  if (str('required_java_version').isNotEmpty) {
    androidLines.add(
      "requiredJavaVersion: '${_esc(str('required_java_version'))}'",
    );
  }
  final enableOpt = androidMap['enable_optimization'];
  if (enableOpt == true) androidLines.add('enableOptimization: true');
  final proguard = _yStrings(androidMap['proguard_files']);
  if (proguard.isNotEmpty) {
    androidLines.add('proguardFiles: ${_strList(proguard)}');
  }
  for (final key in androidMap.keys) {
    if (!const [
      'package_name',
      'application_id',
      'compile_sdk',
      'target_sdk',
      'min_sdk',
      'version_code',
      'version_name',
      'source_dirs',
      'abis',
      'java_version',
      'kotlin_version',
      'required_java_version',
      'enable_optimization',
      'proguard_files',
      'icon',
      'res_dirs',
      'manifest',
      'signing',
    ].contains(key)) {
      notices.add('android.$key is not auto-converted — port by hand');
    }
  }

  // ── FlutterBuild ────────────────────────────────────────────────────
  final flutterLines = <String>[];
  String fstr(String key) => _yStr(flutterMap[key]);
  if (fstr('entrypoint').isNotEmpty) {
    flutterLines.add("entrypoint: '${_esc(fstr('entrypoint'))}'");
  }
  final assets = _yStrings(flutterMap['assets']);
  if (assets.isNotEmpty) flutterLines.add('assets: ${_strList(assets)}');
  final buildArgs = _yStrings(flutterMap['build_args']);
  if (buildArgs.isNotEmpty) {
    flutterLines.add('buildArgs: ${_strList(buildArgs)}');
  }
  if (fstr('build_mode').isNotEmpty) {
    flutterLines.add("buildMode: '${_esc(fstr('build_mode'))}'");
  }
  if (fstr('target_platform').isNotEmpty) {
    flutterLines.add("targetPlatform: '${_esc(fstr('target_platform'))}'");
  }
  if (flutterMap['tree_shake_icons'] == true) {
    flutterLines.add('treeShakeIcons: true');
  }
  if (flutterMap['enable_hot_reload'] == true) {
    flutterLines.add('enableHotReload: true');
  }
  if (flutterMap['deferred_components'] == true) {
    flutterLines.add('deferredComponents: true');
  }
  if (fstr('engine_path').isNotEmpty) {
    flutterLines.add("enginePath: '${_esc(fstr('engine_path'))}'");
  }
  if (fstr('engine_version').isNotEmpty) {
    flutterLines.add("engineVersion: '${_esc(fstr('engine_version'))}'");
  }
  for (final key in flutterMap.keys) {
    if (!const [
      'entrypoint',
      'assets',
      'build_args',
      'build_mode',
      'target_platform',
      'tree_shake_icons',
      'enable_hot_reload',
      'deferred_components',
      'engine_path',
      'engine_version',
    ].contains(key)) {
      notices.add('flutter.$key is not auto-converted — port by hand');
    }
  }

  // ── PipelineOverrides ───────────────────────────────────────────────
  final overrideLines = <String>[];
  final extraDeps = _yStrings(pipelineMap['extra_deps']);
  if (extraDeps.isNotEmpty) {
    overrideLines.add('extraDeps: ${_strList(extraDeps)}');
  }
  final extraAssets = pipelineMap['extra_assets'];
  if (extraAssets is List && extraAssets.isNotEmpty) {
    final pairs = <String>[];
    for (final e in extraAssets) {
      if (e is Map) {
        pairs.add(
          "(from: '${_esc(e['from']?.toString() ?? '')}', "
          "to: '${_esc(e['to']?.toString() ?? '')}')",
        );
      }
    }
    if (pairs.isNotEmpty) {
      overrideLines.add('extraAssets: [${pairs.join(', ')}]');
    }
  }
  final localAars = _yStrings(pipelineMap['local_aars']);
  if (localAars.isNotEmpty) {
    overrideLines.add('localAars: ${_strList(localAars)}');
  }
  final resDirs = _yStrings(androidMap['res_dirs']);
  if (resDirs.isNotEmpty) {
    overrideLines.add('resDirs: ${_strList(resDirs)}');
  }
  final resourceConfigs = _yStrings(pipelineMap['resource_configs']);
  if (resourceConfigs.isNotEmpty) {
    overrideLines.add('resourceConfigs: ${_strList(resourceConfigs)}');
  }
  final excludePlugins = _yStrings(pipelineMap['exclude_plugins']);
  if (excludePlugins.isNotEmpty) {
    overrideLines.add('excludePlugins: ${_strList(excludePlugins)}');
  }
  if (pipelineMap['max_size_mb'] is int) {
    overrideLines.add('maxSizeMb: ${pipelineMap['max_size_mb']}');
  }
  final icon = androidMap['icon'];
  if (icon is Map) {
    final iconLines = <String>[];
    if (_yStr(icon['background_color']).isNotEmpty) {
      iconLines.add(
        "backgroundColor: '${_esc(_yStr(icon['background_color']))}'",
      );
    }
    if (_yStr(icon['vector']).isNotEmpty) {
      iconLines.add("vector: '${_esc(_yStr(icon['vector']))}'");
    }
    if (_yStr(icon['monochrome']).isNotEmpty) {
      iconLines.add("monochrome: '${_esc(_yStr(icon['monochrome']))}'");
    }
    if (iconLines.isNotEmpty) {
      overrideLines.add('icon: const IconConfig(${iconLines.join(', ')})');
    }
  }
  final pipelineDeeplinks = _deeplinks(pipelineMap['deeplinks']);
  if (pipelineDeeplinks.isNotEmpty) {
    overrideLines.add('deeplinks: [${pipelineDeeplinks.join(', ')}]');
  }
  final manifest = androidMap['manifest'];
  if (manifest is Map) {
    final m = _manifestLines(manifest, notices);
    if (m.isNotEmpty) {
      overrideLines.add('manifest: const ManifestSpec(${m.join(', ')})');
    }
  }
  if (androidMap['signing'] != null) {
    notices.add(
      'android.signing holds secrets — keep it in oka.yaml (or '
      'android/key.properties); do not delete the yaml until migrated',
    );
  }
  for (final key in pipelineMap.keys) {
    if (!const [
      'extra_deps',
      'extra_assets',
      'local_aars',
      'resource_configs',
      'exclude_plugins',
      'max_size_mb',
      'deeplinks',
      'dart_entrypoint',
    ].contains(key)) {
      notices.add('pipeline.$key is not auto-converted — port by hand');
    }
  }

  // ── Assemble the file ───────────────────────────────────────────────
  final b = StringBuffer();
  b.writeln('// Generated by `oka init` (ADR-0010) — typed, programmable');
  b.writeln('// project config. oka.yaml is optional: precedence is');
  b.writeln('// defaults < oka.yaml (if kept) < this file < CLI args');
  b.writeln('// (--release/--aab/--abi/--dart-define/...).');
  if (doc['name'] != null || doc['version'] != null) {
    b.writeln(
      "// Project: ${doc['name'] ?? ''} ${doc['version'] ?? ''} (from oka.yaml)",
    );
  }
  b.writeln("import 'package:oka_android/oka_android.dart';");
  b.writeln("import 'package:oka_core/oka_core.dart';");
  b.writeln();
  b.writeln('Future<void> main(List<String> args) => okaRun(');
  b.writeln('  args,');
  b.writeln('  oka: Oka(');
  b.writeln('    pipelines: [');
  b.writeln('      AndroidPipeline(');
  if (androidLines.isNotEmpty) {
    b.writeln('        config: AndroidBuild(');
    for (final l in androidLines) {
      b.writeln('          $l,');
    }
    b.writeln('        ),');
  }
  if (flutterLines.isNotEmpty) {
    b.writeln('        flutterConfig: FlutterBuild(');
    for (final l in flutterLines) {
      b.writeln('          $l,');
    }
    b.writeln('        ),');
  }
  if (overrideLines.isNotEmpty) {
    b.writeln('        overrides: PipelineOverrides(');
    for (final l in overrideLines) {
      b.writeln('          $l,');
    }
    b.writeln('        ),');
  }
  b.writeln('        steps: [...AndroidPipeline.defaultSteps],');
  b.writeln('      ),');
  b.writeln('    ],');
  b.writeln('  ),');
  b.writeln(');');
  for (final n in notices) {
    b.writeln();
    b.writeln('// ⚠️  NOT AUTO-CONVERTED: $n');
  }
  return OkaInitResult(code: b.toString(), notices: notices);
}

List<String> _manifestLines(
  Map<dynamic, dynamic> manifest,
  List<String> notices,
) {
  final lines = <String>[];
  final permissions = _yStrings(manifest['permissions']);
  if (permissions.isNotEmpty) {
    lines.add('permissions: ${_strList(permissions)}');
  }
  if (manifest['cleartext_traffic'] == true) {
    lines.add('cleartextTraffic: true');
  }
  if (manifest['flutter_deeplinking'] == true) {
    lines.add('flutterDeeplinking: true');
  }
  if (manifest['debuggable'] == false) lines.add('debuggable: false');
  if (manifest['extract_native_libs'] == false) {
    lines.add('extractNativeLibs: false');
  }
  final appAttrs = manifest['application_attributes'];
  if (appAttrs is Map && appAttrs.isNotEmpty) {
    lines.add('applicationAttributes: ${_strMap(appAttrs)}');
  }
  final actAttrs = manifest['activity_attributes'];
  if (actAttrs is Map && actAttrs.isNotEmpty) {
    lines.add('activityAttributes: ${_strMap(actAttrs)}');
  }
  final metaData = manifest['application_meta_data'];
  if (metaData is List && metaData.isNotEmpty) {
    final entries = <String>[];
    for (final e in metaData) {
      if (e is Map && e['name'] != null) {
        final value = e['value'];
        final resource = e['resource'];
        if (value != null) {
          entries.add(
            "MetaDataSpec(name: '${_esc(e['name'].toString())}', "
            "value: '${_esc(value.toString())}')",
          );
        } else if (resource != null) {
          entries.add(
            "MetaDataSpec(name: '${_esc(e['name'].toString())}', "
            "resource: '${_esc(resource.toString())}')",
          );
        }
      }
    }
    if (entries.isNotEmpty) {
      lines.add('applicationMetaData: [${entries.join(', ')}]');
    }
  }
  final manifestDeeplinks = _deeplinks(manifest['deeplinks']);
  if (manifestDeeplinks.isNotEmpty) {
    lines.add('deeplinks: [${manifestDeeplinks.join(', ')}]');
  }
  for (final key in manifest.keys) {
    if (!const [
      'permissions',
      'cleartext_traffic',
      'flutter_deeplinking',
      'debuggable',
      'extract_native_libs',
      'application_attributes',
      'activity_attributes',
      'application_meta_data',
      'deeplinks',
    ].contains(key)) {
      notices.add('android.manifest.$key is not auto-converted');
    }
  }
  return lines;
}

List<String> _deeplinks(final Object? raw) {
  final links = <String>[];
  if (raw is! List) return links;
  for (final e in raw) {
    if (e is Map && e['scheme'] != null) {
      final host = e['host'] == null ? '' : _esc(e['host'].toString());
      final prefix = e['pathPrefix'] == null
          ? ''
          : _esc(e['pathPrefix'].toString());
      links.add(
        "DeeplinkConfig(scheme: '${_esc(e['scheme'].toString())}', "
        "host: '$host', pathPrefix: '$prefix')",
      );
    }
  }
  return links;
}

String _esc(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

String _yStr(final Object? raw) => raw?.toString() ?? '';

List<String> _yStrings(final Object? raw) =>
    raw is List ? raw.map((final e) => e.toString()).toList() : const [];

String _strList(List<String> items) =>
    '[${items.map((e) => "'${_esc(e)}'").join(', ')}]';

String _strMap(Map<dynamic, dynamic> map) =>
    'const {'
    '${map.entries.map((e) => "'${_esc(e.key.toString())}': '${_esc(e.value.toString())}'").join(', ')}'
    '}';

/// Generated entrypoint code + anything the converter could not port.
class OkaInitResult {
  const OkaInitResult({required this.code, required this.notices});
  final String code;
  final List<String> notices;
}
