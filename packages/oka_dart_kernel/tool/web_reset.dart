/// Web-leg baseline reset for the live-e2e gate: waits for the DDK app in
/// the CDP-attached page, hard-reloads it, and asserts the pre-patch
/// baseline value — retrying with full diagnostics (bash string handling
/// proved too fragile for this sequence).
///
/// Usage: dart tool/web_reset.dart <cdpHttpPort> <expectedBaseline>
/// Exit 0 when the page reports <expectedBaseline>.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final port = args[0];
  final expected = args.length > 1 ? args[1] : 'b';
  final probe =
      "String(dartDevEmbedder.importLibrary('package:headless_core/src/fractional_order.dart').fractionalBetween('a', null))";

  Future<String?> evalOn(String pageWs, String expression) async {
    final ws = await WebSocket.connect(pageWs);
    final pending = <int, Completer<Map<String, dynamic>>>{};
    var id = 0;
    final completer = Completer<Map<String, dynamic>>();
    ws.listen((data) {
      if (data is! String) return;
      final msg = (jsonDecode(data) as Map).cast<String, dynamic>();
      final msgId = msg['id'] as int?;
      if (msgId != null && msgId == id && pending.containsKey(msgId)) {
        pending.remove(msgId)!.complete(msg);
      }
    });
    pending[id] = completer;
    ws.add(jsonEncode({
      'id': id,
      'method': 'Runtime.evaluate',
      'params': {
        'expression': expression,
        'returnByValue': true,
        'awaitPromise': true,
      },
    }));
    try {
      final response =
          await completer.future.timeout(const Duration(seconds: 30));
      final result = response['result'] as Map<String, dynamic>? ?? const {};
      if (result['exceptionDetails'] != null) return null;
      final value = result['result'] as Map? ?? const {};
      return (value['value'] as String?) ??
          (value['description'] as String?) ??
          '';
    } finally {
      await ws.close();
    }
  }

  Future<String?> pageWs() async {
    final body = await httpGetString(Uri.parse('http://127.0.0.1:$port/json/list'));
    final tabs = (jsonDecode(body) as List).cast<Map>();
    for (final tab in tabs) {
      if (tab['type'] == 'page' &&
          (tab['url'] as String? ?? '').contains('127.0.0.1:8187')) {
        return tab['webSocketDebuggerUrl'] as String;
      }
    }
    return null;
  }

  // 1. wait for the page + DDK runtime to answer at all.
  var ws = await pageWs();
  var deadline = DateTime.now().add(const Duration(minutes: 6));
  while (ws == null && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 5));
    ws = await pageWs();
  }
  if (ws == null) {
    stderr.writeln('web_reset: no app page on CDP :$port');
    exitCode = 1;
    return;
  }

  // 2. hard reload so the page re-fetches the CURRENT served bundle, then
  //    wait for the DDK runtime to boot (tens of seconds on a 4k-lib app).
  await evalOn(ws, 'location.reload()');
  await Future<void>.delayed(const Duration(seconds: 10));
  deadline = DateTime.now().add(const Duration(minutes: 8));
  String? value;
  while (DateTime.now().isBefore(deadline)) {
    value = await evalOn(ws!, probe);
    if (value != null && value.isNotEmpty) break;
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  if (value == null || value.isEmpty) {
    stderr.writeln('web_reset: DDK runtime never answered the probe');
    exitCode = 1;
    return;
  }
  stdout.writeln(value);
  if (value != expected) {
    stderr.writeln('web_reset: baseline $value != expected $expected '
        '(served bundle stale — recompile and reload again)');
    exitCode = 1;
  }
}

Future<String> httpGetString(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}
