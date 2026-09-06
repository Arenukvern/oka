import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:yaml/yaml.dart';

import 'composition.dart';
import 'config/build_context.dart';
import 'config/oka_config.dart';

/// Entry-point options accepted by [okaRun] (forwarded by `oka build` when a
/// project declares `pipeline.dart_entrypoint` in oka.yaml).
final _okaRunParser = ArgParser()
  ..addFlag('release', negatable: false, help: 'Build release variant')
  ..addFlag('debug', negatable: false, help: 'Build debug variant (default)')
  ..addFlag('profile', negatable: false, help: 'Build profile variant')
  ..addFlag('aab', negatable: false, help: 'Build AAB instead of APK')
  ..addFlag('verbose', abbr: 'v', negatable: false)
  ..addOption('platform', defaultsTo: 'android')
  ..addOption('flavor', defaultsTo: '')
  ..addOption('abi', defaultsTo: '')
  ..addOption('target', help: 'Flutter entrypoint (e.g. lib/main_prod.dart)')
  ..addMultiOption('dart-define')
  ..addOption('dart-define-from-file')
  // ADR-0010: print the fully merged config map (oka.yaml + typed Dart
  // config) as JSON and exit — used by tooling (e.g. `oka debug step`) to
  // materialize a hook project's config without running a build.
  ..addFlag('print-config', negatable: false, hide: true);

/// Runs a declarative [Oka] composition from a project hook entrypoint
/// (ADR-0006: `oka build` delegates to `dart run <entrypoint>` which calls
/// this).
///
/// Performs the boilerplate hooks should not repeat: arg parsing, oka.yaml
/// loading, dart-define merging, build directory layout, pipeline selection by
/// `--platform`, and execution.
Future<void> okaRun(
  List<String> args, {
  required Oka oka,
  String? projectPath,
  ArgParser? extraArgs,
}) async {
  final parser = _okaRunParser;
  final results = parser.parse(args);

  final verbose = results['verbose'] as bool;
  final platform = results['platform'] as String;
  final pipeline = _selectPipeline(oka, platform);

  final root = projectPath ?? Directory.current.path;
  final mode = results['release'] as bool
      ? BuildMode.release
      : results['profile'] as bool
      ? BuildMode.profile
      : BuildMode.debug;
  final buildAab = results['aab'] as bool;
  final buildDirMode = buildAab ? '${mode.name}-aab' : mode.name;

  final config = await loadOkaYaml(root);
  // ADR-0010: typed Dart config (AndroidPipeline.config/flutterConfig) wins
  // over oka.yaml; empty overrides leave yaml-only projects untouched.
  final mergedMap = mergeConfigMaps(
    config.toJson(),
    pipeline.configOverrides,
  );
  final mergedConfig = OkaConfig.fromJson(mergedMap);

  if (results['print-config'] as bool) {
    stdout.writeln(jsonEncode(mergedMap));
    return;
  }

  final defines = <String, String>{
    ...parseDartDefineFile(results['dart-define-from-file'] as String?),
    for (final d in results['dart-define'] as List<String>)
      ..._parseSingleDefine(d),
  };

  final buildDir = '$root/.oka_cache/build/$buildDirMode';
  await Directory(buildDir).create(recursive: true);

  final ctx = BuildContext(
    projectPath: root,
    buildDir: buildDir,
    mode: mode,
    config: mergedConfig,
    cacheDir: '$root/.oka_cache',
    tempDir: '$buildDir/temp',
    verbose: verbose,
    flavor: results['flavor'] as String,
    targetAbi: results['abi'] as String,
    buildAab: buildAab,
    dartDefines: defines,
    targetOverride: (results['target'] as String?) ?? '',
  );

  final result = await pipeline.run(ctx);
  if (!result.ok) {
    stderr.writeln('❌ oka run failed: ${result.error}');
    exit(1);
  }
  final apkPath = result.data['apk_path'];
  if (apkPath is String && apkPath.isNotEmpty) {
    stdout.writeln('✅ Build complete: $apkPath');
  }
}

/// Deep-merges [override] over [base] (one nested level for the
/// `android:`/`flutter:`/`pipeline:` sections). Keys present only in [base]
/// are preserved; keys in [override] win. Pure — used for the ADR-0010
/// typed-Dart-config-over-yaml precedence.
Map<String, dynamic> mergeConfigMaps(
  Map<String, dynamic> base,
  Map<String, dynamic> override,
) {
  if (override.isEmpty) return base;
  final out = Map<String, dynamic>.of(base);
  for (final entry in override.entries) {
    final existing = out[entry.key];
    if (existing is Map && entry.value is Map) {
      out[entry.key] = mergeConfigMaps(_stringKeyed(existing),
          _stringKeyed(entry.value as Map));
    } else {
      out[entry.key] = entry.value;
    }
  }
  return out;
}

Map<String, dynamic> _stringKeyed(Map<dynamic, dynamic> m) =>
    m.map((k, v) => MapEntry(k.toString(), v));

/// Resolves the project's Dart pipeline entrypoint (ADR-0006/0010):
///
/// 1. `oka.yaml` `pipeline.dart_entrypoint` (explicit),
/// 2. convention: `tool/oka_pipeline.dart`,
/// 3. convention: `bin/oka_pipeline.dart`.
///
/// Returns a project-relative path, or null when the project has no hook
/// (full-YAML project or fresh project). Full-Dart projects (ADR-0010) have
/// no oka.yaml at all — discovery makes them work without any YAML key.
Future<String?> findPipelineEntrypoint(String projectPath) async {
  final config = await loadOkaYaml(projectPath);
  final pipelineSection = config.toJson()['pipeline'];
  final explicit = pipelineSection is Map
      ? pipelineSection['dart_entrypoint']?.toString()
      : null;
  if (explicit != null && explicit.isNotEmpty) return explicit;
  for (final candidate in const ['tool/oka_pipeline.dart', 'bin/oka_pipeline.dart']) {
    if (await File('$projectPath/$candidate').exists()) return candidate;
  }
  return null;
}

PlatformPipeline _selectPipeline(Oka oka, String platform) {
  for (final p in oka.pipelines) {
    if (p.platform == platform) return p;
  }
  throw ArgumentError(
    'No pipeline for platform "$platform". Declared: '
    '${oka.pipelines.map((p) => p.platform).join(', ')}',
  );
}

/// Loads and parses `oka.yaml` from [projectPath]. Missing file → [OkaConfig.empty].
Future<OkaConfig> loadOkaYaml(String projectPath) async {
  final file = File('$projectPath/oka.yaml');
  if (!await file.exists()) return OkaConfig.empty;
  return OkaConfig.fromJson(_yamlToJson(await _loadYamlAny(file)));
}

Future<dynamic> _loadYamlAny(File file) async =>
    loadYaml(await file.readAsString());

dynamic _yamlToJson(dynamic value) {
  if (value is YamlMap) {
    return value.map((k, v) => MapEntry(k.toString(), _yamlToJson(v)));
  } else if (value is YamlList) {
    return value.map(_yamlToJson).toList();
  }
  return value;
}

/// Expands `--dart-define-from-file` (JSON object of string values).
Map<String, String> parseDartDefineFile(String? path) {
  if (path == null || path.isEmpty) return const {};
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('dart-define-from-file not found', path);
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) {
    throw FormatException('dart-define-from-file must be a JSON object', path);
  }
  return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
}

/// Parses a single `key=value` define; a bare key maps to `'true'`
/// (matching the Flutter tool convention).
Map<String, String> _parseSingleDefine(String define) {
  final i = define.indexOf('=');
  if (i < 0) return {define: 'true'};
  return {define.substring(0, i): define.substring(i + 1)};
}
