/// Continuous live-patch watcher for a running Dart VM server lane.
///
/// Where `oka live watch --spec` applies until the first receipt, this
/// runner stays up for the process lifetime: every saved `.dart` file under
/// a `--watch` root is compiled as its library's unit delta and applied to
/// the spec's targets (ADR-0035 invisible loop, server shape). Receipts
/// emit as JSON lines — one per apply, `ready` on startup, `error` on
/// watcher faults — so a supervisor can tail them.
///
/// ```sh
/// dart --packages=<oka package config> tool/oka_live_watch.dart \
///   --spec spec.json \
///   --app-packages-config <target .dart_tool/package_config.json> \
///   --work-dir <stable toolchain dir> \
///   [--kernel-root <oka_dart_kernel checkout>] \
///   [--project <dir>] \
///   [--watch <dir>]...
/// ```
///
/// The spec supplies targets and probes; `patches` and `unit` in it are
/// ignored — each apply derives the unit label from the changed file, and
/// the file's SAVED content is the delta (no source rewriting).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

// ignore_for_file: avoid_print

Future<void> main(List<String> args) async {
  String? specPath;
  String? workDir;
  String? appPackages;
  String? kernelRoot;
  String? project;
  final watchDirs = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--spec':
        specPath = args[++i];
      case '--work-dir':
        workDir = args[++i];
      case '--app-packages-config':
        appPackages = args[++i];
      case '--kernel-root':
        kernelRoot = args[++i];
      case '--project':
        project = args[++i];
      case '--watch':
        watchDirs.add(args[++i]);
      default:
        print(jsonEncode({'event': 'fatal', 'error': 'unknown arg ${args[i]}'}));
        exit(2);
    }
  }
  if (specPath == null ||
      workDir == null ||
      appPackages == null ||
      watchDirs.isEmpty) {
    print(jsonEncode({
      'event': 'fatal',
      'error': 'need --spec, --work-dir, --app-packages-config, --watch',
    }));
    exit(2);
  }
  final specJson = (jsonDecode(File(specPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final targets = [
    for (final t in (specJson['targets'] as List? ?? const []))
      TargetSpec.fromJson((t as Map).cast<String, dynamic>()),
  ];
  final probes = [
    for (final p in (specJson['probes'] as List? ?? const []))
      ProbeSpec.fromJson((p as Map).cast<String, dynamic>()),
  ];
  final root = project ?? Directory.current.path;

  final toolchain = await resolvePipelineToolchain(
    okaDartKernelRoot:
        kernelRoot ?? File.fromUri(Platform.script).parent.parent.path,
    workDir: Directory(workDir),
    appPackagesConfig: appPackages,
  );
  final compile = pipelineDeltaCompiler(toolchain);
  print(jsonEncode({
    'event': 'ready',
    'watching': watchDirs,
    'toolchainHash': toolchain.sdkHash,
  }));

  Future<void> inFlight = Future.value();
  Timer? debounce;
  String? pending;
  var revision = 0;

  Future<void> apply(String path) async {
    revision++;
    final unit =
        path.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.dart$'), '');
    try {
      final receipt = await applyChange(
        LivePatchSpec(
          revision: '${specJson['revision'] ?? 'hot'}-$revision',
          unit: unit,
          patches: const [],
          targets: targets,
          probes: probes,
        ),
        changedFile: path,
        compile: compile,
        root: root,
      );
      print(jsonEncode({
        'event': 'receipt',
        'ok': receipt.ok,
        'unit': receipt.unit,
        'file': path,
        if (receipt.refusal != null) 'refusal': receipt.refusal,
        'targets': [for (final t in receipt.targets) t.toJson()],
      }));
    } catch (e) {
      print(jsonEncode({'event': 'error', 'file': path, 'error': '$e'}));
    }
  }

  void schedule(String path) {
    pending = path;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 500), () {
      final file = pending;
      if (file == null) return;
      pending = null;
      inFlight = inFlight.then((_) => apply(file));
    });
  }

  for (final dir in watchDirs) {
    Directory(dir).watch(recursive: true).listen(
      (event) {
        if (!event.path.endsWith('.dart')) return;
        if (event is FileSystemModifyEvent && !event.contentChanged) return;
        schedule(event.path);
      },
      onError: (Object e) {
        print(jsonEncode({'event': 'error', 'watch': dir, 'error': '$e'}));
      },
    );
  }
  await Completer<void>().future;
}
