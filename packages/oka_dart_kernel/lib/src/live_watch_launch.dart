/// Start [oka_live_watch] with a resolved [PipelineToolchain] (ADR-0035).
///
/// Consumers must not hard-code `example/live_showcase/.build/toolchain`.
library;

import 'dart:convert';
import 'dart:io';

import 'live_pipeline.dart';
import 'package_root.dart';

/// Spec + watch roots for a VM live-watch session.
final class LiveWatchLaunch {
  const LiveWatchLaunch({
    required this.specPath,
    required this.projectRoot,
    required this.appPackagesConfig,
    required this.watchRoots,
    this.parentPid,
    this.workDir,
    this.dartBin,
  });

  final String specPath;
  final String projectRoot;
  final String appPackagesConfig;
  final List<String> watchRoots;
  final int? parentPid;

  /// Stable toolchain cache dir; when null, [resolvePipelineToolchain]
  /// picks `~/.oka/cache/…`.
  final String? workDir;
  final String? dartBin;
}

/// Writes a minimal VM-target spec JSON and returns its path.
String writeVmLiveWatchSpec({
  required Directory runDir,
  required int vmServicePort,
  String targetId = 'hot',
}) {
  final spec = File('${runDir.path}/spec.json');
  spec.writeAsStringSync(
    jsonEncode({
      'revision': 'hot-sync',
      'unit': 'ignored',
      'patches': <Object?>[],
      'targets': [
        {
          'kind': 'vm',
          'id': targetId,
          'ws': 'ws://127.0.0.1:$vmServicePort/ws',
        },
      ],
      'probes': <Object?>[],
    }),
  );
  return spec.path;
}

/// Write the VM spec under [runDir] and spawn the live watcher (ADR-0035
/// consumer entry). Harness/product owners only supply port, roots, and
/// knobs — they must not assemble argv or showcase toolchain paths.
Future<Process> attachVmLiveWatch({
  required Directory runDir,
  required int vmServicePort,
  required String projectRoot,
  required String appPackagesConfig,
  required List<String> watchRoots,
  String targetId = 'hot',
  int? parentPid,
  String? workDir,
  String? dartBin,
}) {
  final specPath = writeVmLiveWatchSpec(
    runDir: runDir,
    vmServicePort: vmServicePort,
    targetId: targetId,
  );
  return startVmLiveWatch(
    LiveWatchLaunch(
      specPath: specPath,
      projectRoot: projectRoot,
      appPackagesConfig: appPackagesConfig,
      watchRoots: watchRoots,
      parentPid: parentPid,
      workDir: workDir,
      dartBin: dartBin,
    ),
  );
}

/// Spawns `tool/oka_live_watch.dart` under the consumer dart + resolved
/// pipeline toolchain. Returns the child [Process].
///
/// Requires `oka_dart_kernel` on the running isolate's package config
/// ([Platform.packageConfig] or the embedder default). Prefer
/// [attachVmLiveWatch] for the common hot-owner shape.
Future<Process> startVmLiveWatch(LiveWatchLaunch launch) async {
  final kernelRoot = await resolveOkaDartKernelRoot();
  final toolchain = await resolvePipelineToolchain(
    okaDartKernelRoot: kernelRoot,
    dartBin: launch.dartBin,
    workDir: launch.workDir != null ? Directory(launch.workDir!) : null,
    appPackagesConfig: launch.appPackagesConfig,
  );
  final workDir = launch.workDir ??
      (toolchain.exe != null
          ? File(toolchain.exe!).parent.path
          : '${Platform.environment['HOME']}/.oka/cache/live-hot/toolchain');
  Directory(workDir).createSync(recursive: true);

  final packages = Platform.packageConfig;
  if (packages == null || packages.isEmpty) {
    throw StateError(
      'package_config_unavailable — run under dart with a package '
      'graph that includes oka_dart_kernel',
    );
  }

  final dart = launch.dartBin ?? Platform.resolvedExecutable;
  final args = <String>[
    '--packages=$packages',
    '$kernelRoot/tool/oka_live_watch.dart',
    '--spec',
    launch.specPath,
    '--app-packages-config',
    launch.appPackagesConfig,
    '--work-dir',
    workDir,
    '--kernel-root',
    kernelRoot,
    '--project',
    launch.projectRoot,
  ];
  if (launch.parentPid != null) {
    args.addAll(['--parent-pid', '${launch.parentPid}']);
  }
  for (final root in launch.watchRoots) {
    if (Directory(root).existsSync()) {
      args.addAll(['--watch', root]);
    }
  }
  return Process.start(dart, args);
}
