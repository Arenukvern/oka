/// ADR-0032 G3-real-B: the per-unit delta lane against the REAL Flutter app
/// under `flutter run`.
///
/// flutter run (macos debug, DDS in front of the VM service) + a unit-sized
/// delta dill applied through the private VM-service `_reloadKernel
/// {kernelFilePath}` -> `evaluate` in the real library scope returns the
/// patched value. No restart.
///
/// Wire facts this gate encodes (all measured on 3.13.x):
/// - The public `reloadSources` has NO kernel-bytes parameter; unknown
///   params are dropped silently. Without a root-lib binary it recompiles
///   from source via the kernel isolate.
/// - The flutter embedder never starts the kernel isolate
///   (`start_kernel_isolate` unset), so that fallback fails with "Error
///   while starting Kernel isolate task" — the payload size was never the
///   blocker.
/// - The stock frontend_server incremental model re-serializes every
///   transitive dependent of the patch: recompile-from-entry OR re-rooted
///   at the unit library both yield the whole component (135MB on
///   last_answer). A small delta must be compiled outside the incremental
///   session — hence the `unit` lane.
///
/// Delta lanes (G3B_DELTA_MODE):
/// - `unit` (default): oka's own pipeline (`tool/gate_pipeline.dart
///   --delta`) compiles the patch unit's library as the reload root —
///   kernelForModule closure pruned to the unit, external references
///   resolved by the VM against the loaded program. 11KB on last_answer.
/// - `fs`: our own flutter-frontend_server instance compiles the app entry
///   incrementally (full-component delta — research reproducibility).
///
/// Config via env (see tool/gate_g3_real_flutter.sh): G3B_APP_ROOT,
/// G3B_FLUTTER, G3B_ENTRY, G3B_UNIT_FILE, G3B_OLD, G3B_NEW, G3B_EXPR,
/// G3B_BEFORE, G3B_AFTER, G3B_MAX_DELTA_BYTES, G3B_DELTA_MODE,
/// G3B_RELOAD_ROOT (fs lane), G3B_DELTA_DART, G3B_DELTA_PACKAGES,
/// G3B_DELTA_CWD, G3B_SDK_HASH (unit lane).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final appRoot = Platform.environment['G3B_APP_ROOT']!;
  final flutter = Platform.environment['G3B_FLUTTER']!;
  final unitFile = Platform.environment['G3B_UNIT_FILE']!;
  final oldMarker = Platform.environment['G3B_OLD']!;
  final newMarker = Platform.environment['G3B_NEW']!;
  final expr = Platform.environment['G3B_EXPR']!;
  final before = Platform.environment['G3B_BEFORE']!;
  final after = Platform.environment['G3B_AFTER']!;
  final maxDeltaBytes =
      int.parse(Platform.environment['G3B_MAX_DELTA_BYTES'] ?? '8388608');
  final fsLane =
      (Platform.environment['G3B_DELTA_MODE'] ?? 'unit') == 'fs';

  final fsDart = '$flutter/bin/cache/dart-sdk/bin/dartaotruntime';
  final fsSnapshot =
      '$flutter/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot';
  final patchedSdk =
      '$flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk';
  final packages = '$appRoot/.dart_tool/package_config.json';

  final unitSource = File(unitFile).readAsStringSync();
  Process? flutterRef;
  Process? fsRef;
  var exitOk = false;
  try {
    // Normalize a patch leftover from a killed run.
    if (unitSource.contains(newMarker)) {
      File(unitFile)
          .writeAsStringSync(unitSource.replaceAll(newMarker, oldMarker));
    }

    // 1. delta-lane state (fs lane only): frontend_server session.
    var fsLines = <String>[];
    void Function(String) send = (String _) {};
    var boundary = '';
    var reloadRootUri = '';
    if (fsLane) {
      final entry = Platform.environment['G3B_ENTRY']!;
      final reloadRoot = Platform.environment['G3B_RELOAD_ROOT'] ?? entry;
      reloadRootUri =
          reloadRoot.startsWith('file:') ? reloadRoot : 'file://$reloadRoot';

      // Our frontend_server (flutter's, flutter target, patched SDK).
      stdout.writeln('g3b: spawning frontend_server');
      final fs = await Process.start(fsDart, [
        fsSnapshot,
        '--incremental',
        '--sdk-root=$patchedSdk',
        '--target=flutter',
        // Platform-free dills, matching flutter_tools' debug compile: a
        // platform-linked delta killed the VM's kernel isolate on reload.
        '--no-link-platform',
        '--packages=$packages',
      ]);
      fsRef = fs;
      fsLines = <String>[];
      fs.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
            fsLines.add,
          );
      fs.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
            (l) => stderr.writeln('[fs] $l'),
          );
      send = (String line) => fs.stdin.writeln(line);

      stdout.writeln('g3b: initial full compile of ${entry.split('/').last} '
          '(whole Flutter app — takes a while)');
      send('compile $entry');
      await _waitFor(fsLines, (l) => l.startsWith('result '),
          timeout: const Duration(minutes: 10), what: 'compile ack');
      boundary = fsLines
          .firstWhere((l) => l.startsWith('result '))
          .substring('result '.length)
          .trim();
      await _waitFor(fsLines, (l) => l.startsWith('$boundary '),
          timeout: const Duration(minutes: 10), what: 'full dill');
      stdout.writeln('g3b: full dill ready (boundary $boundary)');
    }

    // 2. flutter run (DDS sits in front of the VM service).
    stdout.writeln('g3b: flutter run -d macos');
    final flutterProc = await Process.start(
      '$flutter/bin/flutter',
      ['run', '-d', 'macos', '--debug'],
      workingDirectory: appRoot,
    );
    flutterRef = flutterProc;
    final flutterLines = <String>[];
    flutterProc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) {
      flutterLines.add(l);
      stdout.writeln('[flutter] $l');
    });
    flutterProc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => stderr.writeln('[flutter!] $l'));

    final serviceLine = await _waitFor(
      flutterLines,
      (l) => l.contains('A Dart VM Service') && l.contains('http://'),
      timeout: const Duration(minutes: 10),
      what: 'dds service uri',
    );
    final serviceUri = RegExp(r'http://\S+').firstMatch(serviceLine)![0]!;
    final wsUri = serviceUri.startsWith('ws://')
        ? serviceUri
        : '${serviceUri.replaceFirst('http://', 'ws://')}ws';
    stdout.writeln('g3b: service $wsUri');

    final rpc = await _rpcChannel(wsUri);

    // 3. locate the main isolate + the real library.
    final vm = (await rpc('getVM'))['result'] as Map<String, dynamic>;
    final isolateIds = ((vm['isolateIds'] ?? vm['isolates']) as List)
        .map((e) => (e as Map)['id'] as String)
        .toList();
    String? libId;
    String? isolateId;
    for (final id in isolateIds) {
      final isolate =
          (await rpc('getIsolate', {'isolateId': id}))['result']
              as Map<String, dynamic>;
      final libs = (isolate['libraries'] as List? ?? const []).cast<Map>();
      final found = libs.where(
        (l) => (l['uri'] as String? ?? '').contains('fractional_order.dart'),
      );
      if (found.isNotEmpty) {
        libId = found.first['id'] as String;
        isolateId = id;
        break;
      }
    }
    stdout.writeln('g3b: isolate=$isolateId library=$libId');
    if (libId == null || isolateId == null) {
      throw StateError('fractional_order library not found in the running app');
    }

    Future<String> evalValue() async {
      final r = await rpc('evaluate',
          {'isolateId': isolateId, 'targetId': libId, 'expression': expr});
      if (r['error'] != null) throw StateError('evaluate failed: $r');
      final result = r['result'] as Map<String, dynamic>;
      return (result['valueAsString'] as String?) ?? jsonEncode(result);
    }

    final valueBefore = await evalValue();
    stdout.writeln('g3b: evaluate before = $valueBefore');
    if (!valueBefore.contains(before)) {
      throw StateError('expected `$before` before patch, got `$valueBefore`');
    }

    // 4. patch the real module source.
    final current = File(unitFile).readAsStringSync();
    final patched = current.replaceFirst(oldMarker, newMarker);
    if (patched == current) throw StateError('patch marker not found');
    File(unitFile).writeAsStringSync(patched);

    // 5. produce the delta dill.
    String deltaPath;
    List<int> deltaBytes;
    if (fsLane) {
      // Recompile -> delta dill, rooted at the patch unit's library
      // (research lane: the stock incremental model re-serializes every
      // transitive dependent of the patch regardless of root).
      final recompileLineCount = fsLines.length;
      send('recompile $reloadRootUri $boundary');
      send('file://$unitFile');
      send(boundary);
      final countBefore = fsLines.where((l) => l.startsWith('result ')).length;
      await _waitForAckOrError(
        fsLines,
        fromIndex: recompileLineCount,
        countBefore: countBefore,
        timeout: const Duration(minutes: 10),
        what: 'recompile ack',
      );
      final boundary2 = fsLines
          .where((l) => l.startsWith('result '))
          .last
          .substring('result '.length)
          .trim();
      await _waitFor(fsLines, (l) => l.startsWith('$boundary2 '),
          timeout: const Duration(minutes: 10), what: 'delta dill');
      final deltaDill =
          fsLines.lastWhere((l) => l.startsWith('$boundary2 ')).split(' ')[1];
      deltaPath = deltaDill;
      deltaBytes = await File(deltaDill).readAsBytes();
      stdout.writeln('g3b: fs delta dill rooted at '
          '${reloadRootUri.split('/').last} (${deltaBytes.length} bytes)');
    } else {
      (deltaPath, deltaBytes) = await _unitDelta(unitFile);
      stdout.writeln('g3b: unit delta for ${unitFile.split('/').last} '
          '(${deltaBytes.length} bytes)');
    }
    if (deltaBytes.length > maxDeltaBytes) {
      throw StateError(
          'delta is ${deltaBytes.length} bytes > $maxDeltaBytes — '
          'not unit-sized (full-component regression)');
    }

    // 6. apply the delta through DDS. The public reloadSources has no
    // kernel-bytes parameter — without a root-lib binary it falls back to
    // recompiling from source via the kernel isolate, which the flutter
    // embedder never starts ("Error while starting Kernel isolate task").
    // The private _reloadKernel reads the kernel file with the VM's own
    // file callbacks and loads it as the reload delta — the desktop lane
    // (the file is local to the app process).
    final reload = await rpc('_reloadKernel', {
      'isolateId': isolateId,
      'kernelFilePath': deltaPath,
    });
    stdout.writeln('g3b: _reloadKernel -> ${jsonEncode(reload)}');
    if (reload['error'] != null) {
      throw StateError('reload failed: ${jsonEncode(reload)}');
    }
    if (fsLane) send('accept');

    // 7. evaluate again — the real library returns the patched value.
    final valueAfter = await evalValue();
    stdout.writeln('g3b: evaluate after = $valueAfter');
    exitOk = valueAfter.contains(after) && !valueAfter.contains(before);
    stdout.writeln(exitOk
        ? 'G3-B: PASS — real Flutter app live-patched through the '
            '${fsLane ? 'frontend_server' : 'per-unit'} delta lane'
        : 'G3-B: FAIL — evaluate did not return the patched value');
    flutterProc.stdin.writeln('q');
  } finally {
    File(unitFile).writeAsStringSync(unitSource);
    fsRef?.kill();
    flutterRef?.kill();
  }
  if (!exitOk) exitCode = 1;
}

/// Compiles the patch unit's library as the reload root with oka's own
/// pipeline (`tool/gate_pipeline.dart --delta`: kernelForProgram closure of
/// the unit pruned to the unit itself; no global transforms — a JIT delta).
/// The subprocess needs the checkout kernel stack on --packages and the
/// compile-time env (DART_SDK_SUMMARY, DART_PACKAGES_CONFIG, OKA_TARGET,
/// OKA_TARGET_OS) inherited from the gate script. Returns (path, bytes).
Future<(String, List<int>)> _unitDelta(String unitFile) async {
  final dartBin = Platform.environment['G3B_DELTA_DART']!;
  final deltaPackages = Platform.environment['G3B_DELTA_PACKAGES']!;
  final cwd = Platform.environment['G3B_DELTA_CWD'] ?? '.';
  final sdkHash = Platform.environment['G3B_SDK_HASH'];
  final tmp = await Directory.systemTemp.createTemp('g3b-unit-delta');
  final out = '${tmp.path}/unit.delta.dill';
  final proc = await Process.run(
    dartBin,
    [
      if (sdkHash != null && sdkHash.isNotEmpty) '-Dsdk_hash=$sdkHash',
      '--packages=$deltaPackages',
      'tool/gate_pipeline.dart',
      '--delta',
      unitFile,
      out,
    ],
    workingDirectory: cwd,
  );
  stdout.writeln('[delta] ${proc.stdout}');
  if (proc.exitCode != 0) {
    stderr.writeln(proc.stderr);
    throw StateError('unit delta compile failed (${proc.exitCode})');
  }
  return (out, File(out).readAsBytesSync());
}

Future<String> _waitFor(
  List<String> lines,
  bool Function(String) test, {
  int? count,
  required Duration timeout,
  required String what,
}) async {
  int seen() =>
      count == null ? (lines.any(test) ? 1 : 0) : lines.where(test).length;
  final target = count ?? 1;
  final deadline = DateTime.now().add(timeout);
  while (seen() < target) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waited for $what', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return count == null ? lines.firstWhere(test) : lines.lastWhere(test);
}

/// Waits for the next `result <boundary-key>` ack line, but fails fast when
/// the server prints an error after [fromIndex] (e.g. a rejected recompile
/// entrypoint) instead of burning the full timeout.
Future<void> _waitForAckOrError(
  List<String> lines, {
  required int fromIndex,
  required int countBefore,
  required Duration timeout,
  required String what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (lines.where((l) => l.startsWith('result ')).length <= countBefore) {
    final errorLine = lines.skip(fromIndex).firstWhere(
          (l) => l.toLowerCase().contains('error'),
          orElse: () => '',
        );
    if (errorLine.isNotEmpty) {
      throw StateError('frontend_server failed $what: $errorLine');
    }
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waited for $what', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

typedef Rpc = Future<Map<String, dynamic>> Function(String method,
    [Map<String, dynamic>? params]);

Future<Rpc> _rpcChannel(String wsUri) async {
  final ws = await WebSocket.connect(wsUri);
  final pending = <String, Completer<Map<String, dynamic>>>{};
  var rpcId = 0;
  ws.listen((data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    final id = msg['id'] as String?;
    stdout.writeln('g3b: <- ${msg['method'] ?? msg['type']}'
        '${id != null ? ' id=$id' : ''}');
    if (id != null && pending.containsKey(id)) {
      pending.remove(id)!.complete(msg);
    }
  });
  return (String method, [Map<String, dynamic>? params]) {
    final id = 'r${rpcId++}';
    final completer = Completer<Map<String, dynamic>>();
    pending[id] = completer;
    ws.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    final minutes = int.parse(Platform.environment['G3B_RPC_MINUTES'] ?? '3');
    return completer.future.timeout(Duration(minutes: minutes));
  };
}
