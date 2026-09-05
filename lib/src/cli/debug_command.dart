import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// `oka debug step <name>` — probe runner (ADR-0007 meta-learnings: running a
/// single step against existing `.oka_cache` output turned 10-minute loops
/// into 30-second ones).
///
/// Runs the default no-Gradle pipeline **up to and including** the named step
/// (a single step cannot run without its upstream artifacts; the incremental
/// step cache keeps the prefix cheap on warm `.oka_cache`).
class DebugCommand {
  Future<void> run(List<String> args) async {
    if (args.isEmpty || args.first == '--help' || args.first == '-h') {
      _printUsage();
      exit(args.isEmpty ? 2 : 0);
    }
    final sub = args.first;
    final rest = args.skip(1).toList();
    switch (sub) {
      case 'step':
        await _runStep(rest);
      default:
        print('Unknown debug subcommand: $sub');
        _printUsage();
        exit(2);
    }
  }

  Future<void> _runStep(List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'project',
        abbr: 'p',
        defaultsTo: Directory.current.path,
        help: 'Project root (defaults to cwd)',
      )
      ..addFlag('release', negatable: false, help: 'Release variant')
      ..addFlag('profile', negatable: false, help: 'Profile variant')
      ..addFlag('aab', negatable: false, help: 'AAB pipeline steps')
      ..addFlag('verbose', abbr: 'v', negatable: false)
      ..addFlag('list', negatable: false, help: 'List available steps')
      ..addOption('flavor', defaultsTo: '')
      ..addOption('abi', defaultsTo: '')
      ..addOption('target')
      ..addMultiOption('dart-define')
      ..addOption('dart-define-from-file');
    final results = parser.parse(args);
    final stepName = results.rest.isEmpty ? null : results.rest.first;
    final list = results['list'] as bool;
    final steps = AndroidPipeline.defaultSteps;

    if (stepName == null || list) {
      print('Available steps (AndroidPipeline.defaultSteps):');
      for (final s in steps) {
        print('  ${s.name.padRight(24)}→ [${s.provides.map((a) => a.id).join(', ')}]');
      }
      print('\nUsage: oka debug step <name> [--project <path>] [--release] [--aab]');
      exit(stepName == null ? 2 : 0);
    }

    final prefix = selectStepPrefix(steps, stepName);
    if (prefix == null) {
      print('❌ unknown step: "$stepName"');
      print('\nAvailable steps:');
      for (final s in steps) {
        print('  ${s.name}');
      }
      exit(2);
    }

    final projectPath = p.normalize(results['project'] as String);

    // Config resolution (ADR-0010): oka.yaml → or, for full-Dart hook
    // projects, materialize the typed config by asking the hook itself
    // (`okaRun --print-config` prints the merged map). Single source of truth.
    OkaConfig config;
    if (File(p.join(projectPath, 'oka.yaml')).existsSync()) {
      config = await loadOkaYaml(projectPath);
    } else {
      final entrypoint = await findPipelineEntrypoint(projectPath);
      if (entrypoint == null) {
        print('❌ no oka.yaml and no Dart pipeline entrypoint in $projectPath');
        print('   Run `oka init` first, or create tool/oka_pipeline.dart');
        exit(2);
      }
      print('🪝 full-Dart project — materializing config from $entrypoint...');
      final proc = await Process.run(
        'dart',
        ['run', entrypoint, '--print-config'],
        workingDirectory: projectPath,
        runInShell: true,
      );
      if (proc.exitCode != 0) {
        print('❌ failed to read config from $entrypoint:\n${proc.stderr}');
        exit(2);
      }
      final decoded = jsonDecode((proc.stdout as String).trim());
      if (decoded is! Map) {
        print('❌ $entrypoint --print-config did not emit a JSON object');
        exit(2);
      }
      config = OkaConfig.fromJson(
        decoded.map((k, v) => MapEntry(k.toString(), v)),
      );
    }

    final mode = results['release'] as bool
        ? BuildMode.release
        : results['profile'] as bool
        ? BuildMode.profile
        : BuildMode.debug;
    final buildAab = results['aab'] as bool;
    final buildDirMode = buildAab ? '${mode.name}-aab' : mode.name;

    // Same context building as `okaRun` (ADR-0006): merged config + defines
    // + `.oka_cache` layout, so probed steps see exactly what a build sees.
    final defines = <String, String>{
      ...parseDartDefineFile(results['dart-define-from-file'] as String?),
      for (final d in results['dart-define'] as List<String>)
        ..._parseSingleDefine(d),
    };
    final buildDir = p.join(projectPath, '.oka_cache', 'build', buildDirMode);
    await Directory(buildDir).create(recursive: true);

    final ctx = BuildContext(
      projectPath: projectPath,
      buildDir: buildDir,
      mode: mode,
      config: config,
      cacheDir: p.join(projectPath, '.oka_cache'),
      tempDir: p.join(buildDir, 'temp'),
      verbose: true,
      flavor: results['flavor'] as String,
      targetAbi: results['abi'] as String,
      buildAab: buildAab,
      dartDefines: defines,
      targetOverride: (results['target'] as String?) ?? '',
    );

    print(
      '🔬 oka debug step — running "${steps[prefix.length - 1].name}" '
      '(${prefix.length} step${prefix.length == 1 ? '' : 's'} incl. upstream '
      'cache hit${prefix.length == 1 ? '' : 's'})\n',
    );

    final pipeline = Pipeline(prefix, verbose: true);
    final validationError = pipeline.validate();
    if (validationError != null) {
      print('❌ $validationError');
      exit(1);
    }

    final result = await pipeline.run(ctx);
    if (!result.ok) {
      print('\n❌ step failed: ${result.error}');
      exit(1);
    }
    print('\n✅ step "$stepName" completed');
  }

  /// Parses a single `key=value` define; bare key → 'true'
  /// (matches `okaRun` convention).
  static Map<String, String> _parseSingleDefine(String define) {
    final i = define.indexOf('=');
    if (i < 0) {
      return {define: 'true'};
    }
    return {define.substring(0, i): define.substring(i + 1)};
  }
}

void _printUsage() {
  print('''
Usage: oka debug <subcommand>

Subcommands:
  step <name>   Run one default-pipeline step (plus its upstream prefix)
                against the project's .oka_cache with verbose output.

Examples:
  oka debug step compile-and-dex
  oka debug step plugin-packaging --project /path/to/app
  oka debug step --list
''');
}

/// Returns the longest prefix of [steps] ending at the step named [name],
/// or null when no step matches. Single-step probes still receive their
/// upstream artifacts, so the prefix must include providers.
List<BuildStep>? selectStepPrefix(List<BuildStep> steps, String name) {
  for (var i = 0; i < steps.length; i++) {
    if (steps[i].name == name) {
      return steps.sublist(0, i + 1);
    }
  }
  return null;
}
