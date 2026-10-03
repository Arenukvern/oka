/// ADR-0032 G3: the per-unit delta lane applied live.
///
/// run the app with the VM service on -> edit a real unit source ->
/// `tool/gate_pipeline.dart --delta` compiles the patched unit's library as
/// the reload root (kernelForModule + prune) -> `_reloadKernel
/// {kernelFilePath}` over the VM service websocket -> the running process
/// prints the NEW label. No restart.
///
/// Wire facts this gate encodes (measured on 3.13.x, see the evidence doc):
/// - The public `reloadSources` has NO kernel-bytes parameter; unknown
///   params are dropped silently. Without a root-lib binary it recompiles
///   from source via the kernel isolate (the stock `dart` VM has one, so
///   source-side reload works there — but it never consumes our bytes).
/// - The frontend_server's incremental `recompile` output is NOT a valid
///   reload payload: the VM's `DeltaProgram::ReadFromTypedData` fails to
///   parse it (RELEASE_ASSERT `delta_program != nullptr` crashes the VM).
///   The per-unit `--delta` dill (plain writeComponentFile of a pruned
///   component) parses on both 3.13.2 and 3.13.4 VMs.
///
/// Pure dart:io. Configurable via env so the same orchestrator drives the
/// toy example app (defaults) and real apps (see tool/gate_g3_real_app.sh):
///   G3_ENTRY      entry source the app runs (from source)
///   G3_PACKAGES   package_config for the app process
///   G3_UNIT_FILE  real source file the patch edits
///   G3_OLD/G3_NEW patch marker strings
///   G3_EXPECT     substring that must appear in app output after reload
///   G3_PORT       VM service port (default 8181)
///   G3_APP_DART   dart binary running the app (default: the tool's sdk)
/// Delta compile (inherited env for the subprocess): DART_SDK_SUMMARY,
/// DART_PACKAGES_CONFIG, OKA_TARGET — plus G3_DELTA_DART, G3_DELTA_PACKAGES
/// (checkout kernel stack), G3_DELTA_CWD, G3_SDK_HASH.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

final _pkgDir = Directory.current.path;
final _entry =
    Platform.environment['G3_ENTRY'] ?? '$_pkgDir/example/kernel_app/tool/g3_app.dart';
final _packages = Platform.environment['G3_PACKAGES'];
final _unitFile = Platform.environment['G3_UNIT_FILE'] ??
    '$_pkgDir/example/kernel_app/lib/units/tiny.dart';
final _oldMarker = Platform.environment['G3_OLD'] ?? 'tiny-v1';
final _newMarker = Platform.environment['G3_NEW'] ?? 'tiny-v3-live';
final _expect = Platform.environment['G3_EXPECT'] ?? _newMarker;
final _port = Platform.environment['G3_PORT'] ?? '8181';

Future<void> main() async {
  stdout.writeln('g3: orchestrator starting');
  final unitSource = File(_unitFile).readAsStringSync();
  Process? appRef;
  var exitOk = false;
  try {
    // 1. run the app from SOURCE with the VM service on.
    final appDart = Platform.environment['G3_APP_DART'] ?? '$_sdkRoot/bin/dart';
    final app = await Process.start(
      appDart,
      [
        '--enable-vm-service=$_port',
        '--disable-service-auth-codes',
        if (_packages != null) '--packages=$_packages',
        _entry,
        '--serve',
      ],
    );
    appRef = app;
    final appLines = <String>[];
    void appLine(String l) {
      appLines.add(l);
      stdout.writeln('[app] $l');
    }

    app.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
          appLine,
        );
    app.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
          appLine,
        );

    final serviceLine = await _waitFor(
        appLines,
        (l) => l.contains('The Dart VM service is listening on'),
        timeout: const Duration(seconds: 60),
        what: 'vm service');
    final serviceUri = RegExp(r'http://\S+').firstMatch(serviceLine)![0]!;
    final wsUri = '${serviceUri.replaceFirst('http://', 'ws://')}ws';

    // 2. edit the unit source (normalize a leftover from a killed run first).
    if (unitSource.contains(_newMarker)) {
      File(_unitFile)
          .writeAsStringSync(unitSource.replaceAll(_newMarker, _oldMarker));
    }
    final current = File(_unitFile).readAsStringSync();
    final patched = current.replaceFirst(_oldMarker, _newMarker);
    if (patched == current) throw StateError('patch marker not found');
    File(_unitFile).writeAsStringSync(patched);

    // 3. compile the patched unit's library as the reload root (oka's own
    //    pipeline; the subprocess needs the checkout kernel stack on
    //    --packages and DART_SDK_SUMMARY / DART_PACKAGES_CONFIG / OKA_TARGET
    //    inherited from the gate script).
    final deltaDill = await _unitDelta(_unitFile);
    stdout.writeln('g3: unit delta $deltaDill '
        '(${File(deltaDill).lengthSync()} bytes)');

    // 4. apply the delta through the VM service. Right after
    //    `--enable-vm-service` the main isolate may not be runnable yet
    //    (the service port opens first); the runnable validation then
    //    rejects isolateId — retry until it is up.
    final ws = await WebSocket.connect(wsUri);
    final pending = <String, Completer<Map<String, dynamic>>>{};
    var rpcId = 0;
    final wsSub = ws.listen((data) {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final id = msg['id'] as String?;
      if (id != null && pending.containsKey(id)) {
        pending.remove(id)!.complete(msg);
      }
    });
    Future<Map<String, dynamic>> rpc(String method,
        [Map<String, dynamic>? params]) {
      final id = 'r${rpcId++}';
      final completer = Completer<Map<String, dynamic>>();
      pending[id] = completer;
      final payload = jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      });
      stdout.writeln(
          'g3: rpc $method -> ${payload.length} bytes, '
          'keys=${params?.keys.toList()}');
      ws.add(payload);
      return completer.future.timeout(const Duration(seconds: 60));
    }

    List<String> isolateIdsOf(Map<String, dynamic> vmResult) =>
        ((vmResult['isolateIds'] as List?) ??
                (vmResult['isolates'] as List? ?? []))
            .map((e) => (e as Map)['id'] as String)
            .toList();
    var vmResult = (await rpc('getVM'))['result'] as Map<String, dynamic>;
    var isolateIds = isolateIdsOf(vmResult);
    for (var attempt = 0; attempt < 10 && isolateIds.isEmpty; attempt++) {
      stdout.writeln(
          'g3: no isolates yet (keys=${vmResult.keys.toList()}), retrying');
      await Future<void>.delayed(const Duration(seconds: 2));
      vmResult = (await rpc('getVM'))['result'] as Map<String, dynamic>;
      isolateIds = isolateIdsOf(vmResult);
    }
    if (isolateIds.isEmpty) {
      throw StateError('vm service reports no isolates: $vmResult');
    }
    final isolateId = isolateIds.first;
    stdout.writeln('g3: isolateId=$isolateId');

    Map<String, dynamic> reload = {};
    for (var attempt = 1; attempt <= 30; attempt++) {
      reload = await rpc('_reloadKernel', {
        'isolateId': isolateId,
        'kernelFilePath': deltaDill,
      });
      final err = reload['error'];
      final notRunnableYet = err != null &&
          '${(err['data'] as Map<String, dynamic>?)?['details'] ?? ''}'
              .contains("invalid 'isolateId' parameter");
      if (!notRunnableYet) break;
      stdout.writeln(
          'g3: isolate not runnable yet (attempt $attempt), retrying');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    stdout.writeln('g3: _reloadKernel -> ${jsonEncode(reload)}');
    await wsSub.cancel();

    // 5. observe the new label.
    final newLine = await _waitFor(
        appLines,
        (l) => l.contains(_expect),
        timeout: const Duration(seconds: 30),
        what: 'new label');
    final sawNew = newLine.contains(_expect);
    stdout.writeln(sawNew
        ? 'G3: PASS — live process prints the patched value after _reloadKernel'
        : 'G3: FAIL — new label never appeared');
    exitOk = sawNew && reload['error'] == null;

    app.kill();
  } finally {
    // Failure paths must not leak the app (an orphan holds the VM service
    // port and poisons the next run).
    appRef?.kill();
    File(_unitFile).writeAsStringSync(unitSource);
  }
  if (!exitOk) exitCode = 1;
}

/// Compiles [unitFile] as the reload root with `tool/gate_pipeline.dart
/// --delta` (kernelForModule closure of the unit pruned to the unit itself;
/// no global transforms — a JIT delta). Returns the delta dill path.
Future<String> _unitDelta(String unitFile) async {
  final dartBin = Platform.environment['G3_DELTA_DART']!;
  final deltaPackages = Platform.environment['G3_DELTA_PACKAGES']!;
  final cwd = Platform.environment['G3_DELTA_CWD'] ?? '.';
  final sdkHash = Platform.environment['G3_SDK_HASH'];
  final tmp = await Directory.systemTemp.createTemp('g3-unit-delta');
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
  return out;
}

/// SDK override (G3_SDK_ROOT): the dart running the app.
late final _sdkRoot = Platform.environment['G3_SDK_ROOT'] ??
    File(Platform.resolvedExecutable).parent.parent.path;

Future<String> _waitFor(
  List<String> lines,
  bool Function(String) test, {
  int? count,
  required Duration timeout,
  required String what,
}) {
  int seen() => count == null
      ? (lines.any(test) ? 1 : 0)
      : lines.where(test).length;
  final target = count ?? 1;
  final deadline = DateTime.now().add(timeout);
  while (seen() < target) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waited for $what', timeout);
    }
    return Future<void>.delayed(const Duration(milliseconds: 100))
        .then((_) => _waitFor(lines, test, count: count, timeout: timeout, what: what));
  }
  return Future.value(
      count == null ? lines.firstWhere(test) : lines.lastWhere(test));
}
