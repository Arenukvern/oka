/// Evaluates one JavaScript expression in a browser page over the CDP wire
/// and prints the result. The live-e2e web leg uses it for page resets and
/// baseline assertions (the oka_update session uses the same wire for
/// `webExpression` probes).
///
/// Usage: dart tool/cdp_eval.dart <pageWebSocketUrl> <expression>
/// Exit 0 when the expression evaluated; the value is printed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: cdp_eval.dart <pageWsUrl> <expression>');
    exitCode = 64;
    return;
  }
  final ws = await WebSocket.connect(args[0]);
  final pending = <int, Completer<Map<String, dynamic>>>{};
  var id = 0;
  ws.listen((data) {
    if (data is! String) return;
    final msg = (jsonDecode(data) as Map).cast<String, dynamic>();
    final msgId = msg['id'] as int?;
    if (msgId != null && pending.containsKey(msgId)) {
      pending.remove(msgId)!.complete(msg);
    }
  });
  final completer = Completer<Map<String, dynamic>>();
  final key = id++;
  pending[key] = completer;
  ws.add(jsonEncode({
    'id': key,
    'method': 'Runtime.evaluate',
    'params': {
      'expression': args[1],
      'returnByValue': true,
      'awaitPromise': true,
    },
  }));
  final response =
      await completer.future.timeout(const Duration(seconds: 60));
  final result = response['result'] as Map<String, dynamic>? ?? const {};
  if (result['exceptionDetails'] != null) {
    final details = result['exceptionDetails'] as Map;
    stderr.writeln('cdp exception: '
        '${(details['exception'] as Map?)?['description'] ?? details}');
    exitCode = 1;
  } else {
    final value = result['result'] as Map? ?? const {};
    stdout.writeln((value['value'] as String?) ??
        (value['description'] as String?) ??
        jsonEncode(value));
  }
  await ws.close();
}
