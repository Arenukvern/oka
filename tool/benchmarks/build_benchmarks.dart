import 'dart:async';
import 'dart:convert';
import 'dart:io';

String formatSeconds(Duration duration) =>
    (duration.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(
      2,
    );

String flutterFrameworkVersion(String machineOutput) {
  try {
    final value = jsonDecode(machineOutput);
    if (value is! Map<String, Object?>) return 'unknown';
    final version = value['frameworkVersion'];
    return version is String ? version : '';
  } on FormatException {
    return 'unknown';
  }
}

Map<String, Object?> buildSummary({
  required String timestamp,
  required String runner,
  required bool cold,
  required Map<String, double> results,
  required String okaVersion,
  required String okaCommit,
  required String flutterVersion,
  required String osName,
}) => <String, Object?>{
  'schema': 'oka/build-benchmarks/v1',
  'timestamp': timestamp,
  'project': 'example',
  'runner': runner,
  'cold': cold,
  'results_seconds': results,
  'environment': <String, Object?>{
    'oka_version': okaVersion,
    'oka_commit': okaCommit,
    'flutter_version': flutterVersion,
    'os': osName,
    'note': 'machine-dependent; compare only against similar setups',
  },
};

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.run(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

String defaultRepositoryRoot() =>
    File.fromUri(Platform.script).parent.parent.parent.absolute.path;

final class BenchmarkProcessRunner {
  BenchmarkProcessRunner({required this.workingDirectory});

  final String workingDirectory;
  Process? _activeProcess;
  ProcessSignal? _interruptedSignal;
  int? interruptedExitCode;

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    final interrupted = interruptedExitCode;
    if (interrupted != null) {
      return ProcessResult(0, interrupted, '', 'interrupted');
    }

    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    _activeProcess = process;
    final interruptedSignal = _interruptedSignal;
    if (interruptedSignal != null) process.kill(interruptedSignal);
    try {
      final stdoutFuture = utf8.decoder.bind(process.stdout).join();
      final stderrFuture = utf8.decoder.bind(process.stderr).join();
      final exitCode = await process.exitCode;
      return ProcessResult(
        process.pid,
        exitCode,
        await stdoutFuture,
        await stderrFuture,
      );
    } finally {
      if (identical(_activeProcess, process)) _activeProcess = null;
    }
  }

  void interrupt(ProcessSignal signal) {
    _interruptedSignal ??= signal;
    interruptedExitCode ??= signal == ProcessSignal.sigint ? 130 : 143;
    _activeProcess?.kill(signal);
  }
}

Future<String> _capture(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  String fallback = 'unknown',
}) async {
  try {
    final result = await _run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) return fallback;
    return (result.stdout as String).trim();
  } on ProcessException {
    return fallback;
  }
}

Future<double> _timeStep(
  String label,
  Future<ProcessResult> Function() command,
) async {
  final stopwatch = Stopwatch()..start();
  final result = await command();
  stopwatch.stop();
  if (result.exitCode != 0) {
    throw BenchmarkStepException(label);
  }
  return double.parse(formatSeconds(stopwatch.elapsed));
}

final class BenchmarkStepException implements Exception {
  const BenchmarkStepException(this.label);

  final String label;
}

String _timestamp(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  final utc = time.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}

Future<void> main(List<String> arguments) async {
  final root = Directory(
    Platform.environment['OKA_ROOT'] ?? defaultRepositoryRoot(),
  ).absolute;
  final project = Directory(
    arguments.isEmpty ? '${root.path}/example' : arguments.first,
  ).absolute;
  final cold = arguments.length > 1 && arguments[1] == '--cold';

  if (!File('${project.path}/pubspec.yaml').existsSync()) {
    stderr.writeln('benchmarks: not a Flutter project: ${project.path}');
    exit(2);
  }

  var runner = 'dart-run';
  var executable = 'dart';
  var prefix = ['run', '${root.path}/packages/oka/bin/oka.dart'];
  final globalVersion = await _capture('oka', ['--version'], fallback: '');
  if (globalVersion.isNotEmpty) {
    runner = 'global-snapshot';
    executable = 'oka';
    prefix = <String>[];
  }
  final processRunner = BenchmarkProcessRunner(workingDirectory: project.path);
  Future<ProcessResult> runOka(List<String> args) =>
      processRunner.run(executable, [...prefix, ...args]);

  final outputDirectory = Directory('${root.path}/.steward/benchmark-summaries')
    ..createSync(recursive: true);
  final timestamp = _timestamp(DateTime.now());
  final output = File(
    '${outputDirectory.path}/build-benchmarks-$timestamp.json',
  );
  stdout.writeln(
    '🔬 oka build benchmarks — project: ${project.path} (runner: $runner)',
  );

  final cache = Directory('${project.path}/.oka_cache');
  final backup = Directory('${project.path}/.oka_cache.bench-backup');
  var movedCache = false;
  if (cold && cache.existsSync()) {
    if (backup.existsSync()) {
      stderr.writeln('benchmarks: cache backup already exists: ${backup.path}');
      exit(1);
    }
    stdout.writeln('  --cold: moving .oka_cache aside (restored after run)');
    cache.renameSync(backup.path);
    movedCache = true;
  }
  final interruptSubscriptions = <StreamSubscription<ProcessSignal>>[];
  if (!Platform.isWindows) {
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      interruptSubscriptions.add(
        signal.watch().listen((_) => processRunner.interrupt(signal)),
      );
    }
  }

  try {
    final warmup = await runOka(['explain']);
    if (warmup.exitCode != 0) throw const BenchmarkStepException('warm-up');
    final results = <String, double>{
      'explain': await _timeStep('explain', () => runOka(['explain'])),
      'incremental_build_apk': await _timeStep(
        'incremental-build',
        () => runOka(['build', 'apk']),
      ),
    };
    final apk = '${project.path}/.oka_cache/build/debug/app-debug.apk';
    results['compare_self'] = await _timeStep(
      'compare',
      () => runOka(['compare', apk, apk, '--quiet']),
    );
    results['debug_step_resolve_abis'] = await _timeStep(
      'debug-step',
      () => runOka(['debug', 'step', 'resolve-abis']),
    );

    final okaVersionOutput = globalVersion.isNotEmpty
        ? globalVersion
        : await _capture('dart', [
            'run',
            '${root.path}/packages/oka/bin/oka.dart',
            '--version',
          ], workingDirectory: project.path);
    final flutterOutput = await _capture('flutter', [
      '--version',
      '--machine',
    ], fallback: '');
    final unameSystem = await _capture('uname', ['-s']);
    final unameMachine = await _capture('uname', ['-m']);
    final commit = await _capture('git', [
      'rev-parse',
      '--short',
      'HEAD',
    ], workingDirectory: root.path);
    if (processRunner.interruptedExitCode != null) {
      throw const BenchmarkStepException('interrupted');
    }
    final summary = buildSummary(
      timestamp: timestamp,
      runner: runner,
      cold: cold,
      results: results,
      okaVersion: okaVersionOutput.replaceFirst('Oka version ', '').trim(),
      okaCommit: commit,
      flutterVersion: flutterFrameworkVersion(flutterOutput),
      osName: '$unameSystem $unameMachine',
    );
    const encoder = JsonEncoder.withIndent('  ');
    output.writeAsStringSync('${encoder.convert(summary)}\n');
    stdout.writeln(encoder.convert(results));
    stdout.writeln('📄 summary: ${output.path}');
  } on BenchmarkStepException catch (error) {
    stderr.writeln("benchmarks: step '${error.label}' failed");
    exitCode = processRunner.interruptedExitCode ?? 1;
  } finally {
    for (final subscription in interruptSubscriptions) {
      await subscription.cancel();
    }
    if (movedCache) {
      if (cache.existsSync()) cache.deleteSync(recursive: true);
      backup.renameSync(cache.path);
    }
  }
}
