/// Web target: a DDC/DDK web app served by dwds. dwds implements the
/// VM-service protocol (`reloadSources`, `evaluate`, …) over the same
/// JSON-RPC wire as native — that is the unification this API rides on.
///
/// Division of labor (measured, dwds 27.x / flutter 3.47):
/// - The recompile from patched sources is performed by the serving
///   toolchain (flutter run's frontend_server in DDC/DDK mode; build_runner
///   under `webdev serve`). The spec's `signal`/`pidFile` target fields let
///   the session trigger it declaratively (SIGUSR1 == hot reload for
///   `flutter run`).
/// - The apply is `reloadSources` on the dwds debug service — callable by
///   anyone holding the URI, not only by the toolchain that compiled.
///   Underneath, dwds drives `dartDevEmbedder.hotReload(files, libraries)`
///   in the page (DDK) or `$dartHotReloadStartDwds/EndDwds` (DDC).
/// - Verification (`evaluate` with library scoping) rides the same wire.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'spec.dart';
import 'target.dart';
import 'vm_service_wire.dart';

/// Minimal CDP wire for page-level probes (Runtime.evaluate). The apply
/// still rides the dwds VM service; CDP only observes the page.
// The WebSocket lives as long as the target run; closed via [close].
// ignore_for_file: close_sinks
class _CdpWire {
  _CdpWire._(this._ws);

  final WebSocket _ws;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  var _id = 0;

  static Future<_CdpWire> connect(String pageWsUrl) async {
    final ws = await WebSocket.connect(pageWsUrl);
    final wire = _CdpWire._(ws);
    ws.listen(wire._onData, onError: (Object _) {}, cancelOnError: true);
    return wire;
  }

  void _onData(Object? data) {
    if (data is! String) return;
    final msg = (jsonDecode(data) as Map).cast<String, dynamic>();
    final id = msg['id'] as int?;
    if (id != null && _pending.containsKey(id)) {
      _pending.remove(id)!.complete(msg);
    }
  }

  /// Evaluates [jsExpression] in the page; returns the JSON value.
  Future<String> evaluate(String jsExpression) async {
    final id = _id++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _ws.add(jsonEncode({
      'id': id,
      'method': 'Runtime.evaluate',
      'params': {
        'expression': jsExpression,
        'returnByValue': true,
        'awaitPromise': true,
      },
    }));
    final response = await completer.future
        .timeout(const Duration(seconds: 60));
    final result = response['result'] as Map<String, dynamic>? ?? const {};
    if (result['exceptionDetails'] != null) {
      throw LiveWireException('cdp evaluate failed: '
          '${jsonEncode(result['exceptionDetails'])}');
    }
    final value = result['result'] as Map? ?? const {};
    return (value['value'] as String?) ??
        (value['description'] as String?) ??
        jsonEncode(value);
  }

  Future<void> close() => _ws.close();
}

class WebDwdsTarget implements LivePatchTarget {
  WebDwdsTarget({
    required this.id,
    required this.wsUri,
    this.pidFile,
    this.signal,
    this.cdpPageWsUrl,
  });

  @override
  final String id;
  @override
  final String kind = 'web';

  /// dwds debug-service URI (`ws://.../ws`), printed by `flutter run` as
  /// "A Dart VM Service on Chrome is available at: http://...".
  final String wsUri;

  /// When set, applying sends [signal] (e.g. `USR1`) to this pid — the
  /// declarative recompile trigger for `flutter run`.
  final String? pidFile;
  final String? signal;

  /// Browser CDP page WebSocket for `webExpression` probes.
  final String? cdpPageWsUrl;

  late VmServiceWire _wire;
  late String _isolateId;
  late bool _connected = false;
  _CdpWire? _cdp;

  @override
  Future<void> connect() async {
    if (_connected) return;
    _wire = await VmServiceWire.connect(wsUri);
    final vm = await _wire.rpc('getVM');
    final ids = ((vm['isolateIds'] ?? vm['isolates']) as List? ?? const [])
        .map((e) => (e as Map)['id'] as String)
        .toList();
    if (ids.isEmpty) {
      throw LiveWireException('dwds reports no isolates at $wsUri');
    }
    _isolateId = ids.first;
    _connected = true;
  }

  /// Triggers the platform recompile (SIGUSR1 to `flutter run`), then
  /// applies through dwds' `reloadSources`. The probe side-effect (patched
  /// value live in the page) is checked by the session.
  @override
  Future<ApplyOutcome> apply({
    required String unit,
    required String deltaPath,
    required int deltaBytes,
  }) async {
    if (pidFile != null && signal != null) {
      final pid = File(pidFile!).readAsStringSync().trim();
      final r = await Process.run('kill', ['-${signal!}', pid]);
      if (r.exitCode != 0) {
        throw LiveWireException(
            'signal ${signal!} to pid $pid failed: ${r.stderr}');
      }
    }
    try {
      final sw = Stopwatch()..start();
      await _wire.reloadSources(_isolateId);
      // Liveness fact: the isolate that connected is still the one serving
      // probes. A hot RESTART replaces the isolate; a hot reload does not.
      final vm = await _wire.rpc('getVM');
      final ids = ((vm['isolateIds'] ?? vm['isolates']) as List? ?? const [])
          .map((e) => (e as Map)['id'] as String)
          .toList();
      sw.stop();
      return ApplyOutcome(
        ok: true,
        mode: 'dwds reloadSources',
        wire: {
          'durationMs': sw.elapsedMilliseconds,
          // The delta bytes are produced for cross-target parity and
          // receipting; dwds consumes source, not this artifact.
          'deltaBytesAdvisory': deltaBytes,
          'isolatePersists': ids.contains(_isolateId),
        },
      );
    } on LiveWireException catch (e) {
      return ApplyOutcome(ok: false, mode: 'dwds reloadSources', error: e.message);
    }
  }

  @override
  Future<String> evaluate(ProbeSpec probe) async {
    final webExpression = probe.webExpression;
    if (webExpression != null) {
      _cdp ??= await _CdpWire.connect(cdpPageWsUrl!);
      return _cdp!.evaluate(webExpression);
    }
    final fragment = probe.library;
    if (fragment == null) {
      throw LiveWireException('web probes need a `library` selector');
    }
    final loc = await _wire.findLibrary(fragment);
    return _wire.evaluate(
        isolateId: loc.isolateId,
        libraryId: loc.libraryId,
        expression: probe.expression);
  }

  @override
  Future<void> close() async {
    await _wire.close();
    await _cdp?.close();
    _cdp = null;
  }

  /// Drops the browser wire so the next page probe reconnects — a hot
  /// restart reloads the page and the old CDP WebSocket dies with it.
  Future<void> invalidateCdp() async {
    final cdp = _cdp;
    _cdp = null;
    await cdp?.close();
  }

  @override
  Future<ApplyOutcome> syncAsset({
    required String assetKey,
    required List<int> bytes,
    required String flutterAssetsDir,
  }) async =>
      ApplyOutcome(
        ok: false,
        mode: 'assets-sync',
        error: 'web assets are served by the dev server — an asset change '
            'takes effect on the next page load (`R`)',
        wire: {'assetKey': assetKey},
      );
}
