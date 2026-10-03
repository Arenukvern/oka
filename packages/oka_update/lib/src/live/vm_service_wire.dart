/// Minimal VM-service JSON-RPC wire over WebSocket, shared by every target
/// that speaks the service protocol (stock VM, DDS, dwds). Deliberately
/// dependency-free: one client, the handful of methods the live lane needs,
/// plus the DevFS HTTP push used to place a delta on a device.
///
/// Wire facts encoded here (measured on 3.13.x, see the kernel gates):
/// - The private `_reloadKernel {isolateId, kernelFilePath}` is the only
///   way to hand a prebuilt kernel delta to the VM. The public
///   `reloadSources` drops unknown params silently and falls back to a
///   kernel-isolate source recompile without a root-lib binary.
/// - Right after `--enable-vm-service` the main isolate is not runnable
///   yet; `getIsolate`/`_reloadKernel` reject it until the first tick —
///   hence the retry loop.
/// - Devices (flutter run): the delta reaches the device via the VM's
///   embedded HTTP server — `PUT <http endpoint>` with `dev_fs_name` and
///   `dev_fs_uri_b64` headers and a gzip body (mirrors flutter_tools
///   DevFS); `createDevFS` returns the device-side base URI.
library;

// The WebSocket's lifetime is the run's; the wire owns it, callers close
// it through [VmServiceWire.close].
// ignore_for_file: close_sinks

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class VmServiceWire {
  VmServiceWire._(this._ws);

  final WebSocket _ws;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  var _id = 0;

  static Future<VmServiceWire> connect(String wsUri) async {
    final ws = await WebSocket.connect(wsUri);
    final wire = VmServiceWire._(ws);
    ws.listen(wire._onData, onError: wire._onError);
    return wire;
  }

  void _onData(Object? data) {
    if (data is! String) return;
    final msg = (jsonDecode(data) as Map).cast<String, dynamic>();
    final id = msg['id'] as String?;
    if (id != null && _pending.containsKey(id)) {
      _pending.remove(id)!.complete(msg);
    }
    // Events (streamId on top level) are ignored; the live lane polls.
  }

  void _onError(Object e) {
    for (final c in _pending.values) {
      c.completeError(e);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> rpc(String method,
      [Map<String, dynamic>? params]) async {
    final id = 'live${_id++}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method,
        'params': ?params}));
    final response = await completer.future.timeout(const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('vm-service rpc $method'));
    final err = response['error'];
    if (err != null) {
      final errMap = (err as Map).cast<String, dynamic>();
      throw LiveWireException(
          '$method failed: ${errMap['message']} (${errMap['code']})');
    }
    return (response['result'] as Map? ?? const {}).cast<String, dynamic>();
  }

  /// Finds the (isolateId, libraryId) pair for [libraryFragment]. Retries
  /// while the isolate is not runnable yet (startup race), and bounds each
  /// probe RPC — a booting VM service can answer `getIsolate` very slowly
  /// while libraries stream in (measured: one attempt ate ~5s).
  Future<({String isolateId, String libraryId})> findLibrary(
      String libraryFragment,
      {Duration timeout = const Duration(minutes: 2)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        final vm = await rpc('getVM').timeout(const Duration(seconds: 2));
        final ids = ((vm['isolateIds'] ?? vm['isolates']) as List? ?? const [])
            .map((e) => (e as Map)['id'] as String)
            .toList();
        for (final id in ids) {
          try {
            final isolate = await rpc('getIsolate', {'isolateId': id})
                .timeout(const Duration(seconds: 2));
            final libs = (isolate['libraries'] as List? ?? const [])
                .cast<Map<String, dynamic>>();
            final found = libs.where(
                (l) => (l['uri'] as String? ?? '').contains(libraryFragment));
            if (found.isNotEmpty) {
              return (
                isolateId: id,
                libraryId: found.first['id'] as String,
              );
            }
          } on TimeoutException {
            // Service busy while the program boots — retry.
          } on LiveWireException catch (e) {
            final notRunnable = e.message.contains("invalid 'isolateId'");
            if (!notRunnable) rethrow;
          }
        }
      } on TimeoutException {
        // Service busy while the program boots — retry.
      }
      if (DateTime.now().isAfter(deadline)) {
        throw LiveWireException('library `$libraryFragment` not found in any '
            'isolate within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Evaluates [expression] in [libraryId]'s scope; returns its value as a
  /// string.
  Future<String> evaluate(
      {required String isolateId,
      required String libraryId,
      required String expression}) async {
    final r = await rpc('evaluate',
        {'isolateId': isolateId, 'targetId': libraryId, 'expression': expression});
    return (r['valueAsString'] as String?) ?? jsonEncode(r);
  }

  /// The private delta lane on stock VMs, DDS and the flutter embedder.
  Future<Map<String, dynamic>> reloadKernel(
          {required String isolateId, required String kernelFilePath}) =>
      rpc('_reloadKernel',
          {'isolateId': isolateId, 'kernelFilePath': kernelFilePath});

  /// The public reload (dwds implements it for web; on devices it carries
  /// the DevFS-pushed delta via `rootLibUri`).
  Future<Map<String, dynamic>> reloadSources(String isolateId,
      {String? rootLibUri, String? packagesUri}) =>
      rpc('reloadSources', {
        'isolateId': isolateId,
        // flutter_tools always sends pause:false; mirror it exactly.
        'pause': false,
        'rootLibUri': ?rootLibUri,
        'packagesUri': ?packagesUri,
      });

  /// Pushes [bytes] to a flutter-run device as [deviceUri] (from the
  /// `createDevFS` response) inside DevFS [fsName], mirroring flutter_tools'
  /// DevFS HTTP writer. [httpEndpoint] is the VM-service HTTP address.
  Future<void> devfsWrite({
    required String httpEndpoint,
    required String fsName,
    required String deviceUri,
    required List<int> bytes,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.putUrl(Uri.parse(httpEndpoint));
      request.headers.add('dev_fs_name', fsName);
      request.headers
          .add('dev_fs_uri_b64', base64.encode(utf8.encode(deviceUri)));
      final gz = gzip.encode(bytes);
      request.contentLength = gz.length;
      request.headers.contentType = ContentType.binary;
      request.add(gz);
      final response = await request.close().timeout(const Duration(seconds: 60));
      await response.drain<void>();
      if (response.statusCode != 200) {
        throw LiveWireException(
            'devfs push failed: HTTP ${response.statusCode}');
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Creates a DevFS on the target and returns its device-side base URI.
  /// Dart 3.13 moved DevFS into the runtime service layer and renamed the
  /// RPC to `_createDevFS`; older SDKs expose `createDevFS`. DDS quirk
  /// (measured, dds 5.4): DevFS RPCs answer "Unknown method" until the
  /// client has made one proxied call — a `getVM` warm-up clears it.
  Future<String> devfsCreate(String fsName) async {
    await rpc('getVM');
    // Idempotent create: a previous failed run leaves the FS behind
    // (error 1001); delete and recreate, mirroring flutter_tools.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await rpc('_createDevFS', {'fsName': fsName});
        return r['uri'] as String;
      } on LiveWireException catch (e) {
        final exists = e.message.contains('already exists') ||
            e.message.contains('1001');
        if (exists && attempt == 0) {
          await rpc('_deleteDevFS', {'fsName': fsName});
          continue;
        }
        if (!exists) rethrow;
      }
    }
    final r = await rpc('createDevFS', {'fsName': fsName});
    return r['uri'] as String;
  }

  Future<void> close() => _ws.close();
}

class LiveWireException implements Exception {
  LiveWireException(this.message);
  final String message;
  @override
  String toString() => message;
}
