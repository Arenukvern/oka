/// `oka live` runner — the live-update verbs as a product command
/// (ADR-0036 Tier 2). The published `oka` CLI delegates here when the
/// experimental stack is present (it is `publish_to: none`), so the
/// published package never takes a non-publishable dependency.
///
///   dart tool/oka_live.dart <verify|patch|watch> --spec <spec.json> \
///     [--changed-file <f>] [--watch] [--project <dir>] [--json]
///
/// Exit 0 only when the receipt is ok.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

// ignore_for_file: avoid_print

const _usage = 'usage: oka live <verify|patch|watch> --spec <spec.json>\n'
    '  --changed-file <path>  file already saved; compiles as the delta\n'
    '  --watch                watcher until the first receipt\n'
    '  --project <dir>        root the spec paths resolve against\n'
    '  --json                 emit the receipt as JSON';

/// Parsed `oka live` arguments.
class LiveArgs {
  const LiveArgs({
    required this.verb,
    required this.specPath,
    this.changedFile,
    this.watchOnce = false,
    required this.project,
    this.jsonOut = false,
  });

  /// `verify`, `patch`, or `watch`.
  final String verb;
  final String specPath;
  final String? changedFile;
  final bool watchOnce;
  final String project;
  final bool jsonOut;

  /// Null when the invocation is malformed; [error] then says why.
  static LiveArgs? parse(List<String> args, {String? cwd}) {
    if (args.isEmpty) return null;
    final verb = args.first;
    if (!{'verify', 'patch', 'watch'}.contains(verb)) return null;
    String? spec;
    String? changedFile;
    var watchOnce = false;
    String? project = cwd;
    var jsonOut = false;
    String? value(final String name, final String arg, final int i) {
      if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
      if (arg == '--$name' && i + 1 < args.length) return args[i + 1];
      return null;
    }

    for (var i = 1; i < args.length; i++) {
      final a = args[i];
      final specV = value('spec', a, i);
      if (specV != null) {
        spec = specV;
        if (a == '--spec') i++;
        continue;
      }
      final fileV = value('changed-file', a, i);
      if (fileV != null) {
        changedFile = fileV;
        if (a == '--changed-file') i++;
        continue;
      }
      final projV = value('project', a, i);
      if (projV != null) {
        project = projV;
        if (a == '--project') i++;
        continue;
      }
      if (a == '--watch') {
        watchOnce = true;
      } else if (a == '--json') {
        jsonOut = true;
      } else {
        return null; // unknown token
      }
    }
    if (spec == null || project == null) return null;
    return LiveArgs(
      verb: verb,
      specPath: spec,
      changedFile: changedFile,
      watchOnce: watchOnce,
      project: project,
      jsonOut: jsonOut,
    );
  }
}

/// The CLI body, DI-able for tests (compiler/target overrides instead of
/// the real toolchain; injected sinks instead of stdout).
Future<void> runLiveCli(
  List<String> args, {
  UnitDeltaCompiler? compiler,
  Map<String, LivePatchTarget> targetOverrides = const {},
  void Function(String)? output,
  void Function(String)? errorOutput,
  void Function(int)? setExitCode,
  String? kernelRoot,
  String? workingDir,
}) async {
  final out = output ?? print;
  final err = errorOutput ?? (final m) => stderr.writeln(m);
  final exitWith = setExitCode ?? (final c) => exitCode = c;

  final args0 = args.isNotEmpty && args.first == 'live' ? args.sublist(1) : args;
  final parsed = LiveArgs.parse(args0, cwd: workingDir ?? Directory.current.path);
  if (parsed == null) {
    err(_usage);
    exitWith(2);
    return;
  }
  final specFile = File(parsed.specPath);
  if (!specFile.existsSync()) {
    err('spec not found: ${parsed.specPath}');
    exitWith(2);
    return;
  }
  final specJson =
      (jsonDecode(specFile.readAsStringSync()) as Map).cast<String, dynamic>();

  final toolchain = await resolvePipelineToolchain(
    okaDartKernelRoot:
        kernelRoot ?? File.fromUri(Platform.script).parent.parent.path,
    workDir: Directory.systemTemp,
    appPackagesConfig: '${parsed.project}/.dart_tool/package_config.json',
  );
  final host = _VerbHost(
    compile: compiler ?? pipelineDeltaCompiler(toolchain),
    root: parsed.project,
    targetOverrides: targetOverrides,
  );

  final verbArgs = <String, Object?>{'spec': specJson};
  if (parsed.changedFile != null) verbArgs['changedFile'] = parsed.changedFile;
  if (parsed.watchOnce) verbArgs['watch'] = true;

  try {
    final receipt =
        await runLiveVerb('oka.live.${parsed.verb}', verbArgs, host);
    out(parsed.jsonOut
        ? const JsonEncoder.withIndent('  ').convert(receipt)
        : describeReceipt(receipt));
    exitWith(receipt['ok'] == true ? 0 : 1);
  } catch (e) {
    err('oka live: $e');
    exitWith(1);
  }
}

/// Human receipt render (shared by the runner and the delegating CLI).
String describeReceipt(Map<String, Object?> receipt) {
  final b = StringBuffer()
    ..writeln('live patch ${receipt['ok'] == true ? 'OK' : 'FAILED'} — '
        'unit `${receipt['unit']}` rev ${receipt['revision']}');
  for (final t in (receipt['targets'] as List? ?? const []).cast<Map>()) {
    b.writeln('  ${t['ok'] == true ? '✓' : '✗'} ${t['target']} '
        '(${t['kind']}) via ${t['mode']}');
    for (final p in (t['probes'] as List? ?? const []).cast<Map>()) {
      b.writeln('      probe `${p['probe']}`: '
          '${p['before']} -> ${p['after']}${p['held'] == true ? ' (held)' : ''}');
    }
    if (t['refusal'] != null) b.writeln('      refused: ${t['refusal']}');
  }
  if (receipt['refusal'] != null) b.writeln('  refused: ${receipt['refusal']}');
  return b.toString();
}

class _VerbHost implements LiveVerbHost {
  _VerbHost({
    required this.compile,
    required this.root,
    required this.targetOverrides,
  });
  @override
  final UnitDeltaCompiler compile;
  @override
  final String root;
  @override
  final Map<String, LivePatchTarget> targetOverrides;
  @override
  void Function(LivePatchEvent event)? get onEvent => null;
}

Future<void> main(List<String> args) => runLiveCli(args);
