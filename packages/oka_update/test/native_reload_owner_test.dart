import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

void main() {
  test('native serving owner skips DevFS and duplicate VM reload', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final methods = <String>[];
    WebSocket? socket;
    server.listen((request) async {
      socket = await WebSocketTransformer.upgrade(request);
      socket!.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        final method = message['method'] as String;
        methods.add(method);
        socket!.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': method == 'getVM'
                ? {
                    'isolates': [
                      {'id': 'isolate-1'},
                    ],
                  }
                : {'type': 'ReloadReport', 'success': true},
          }),
        );
      });
    });
    var reloads = 0;
    final target = VmJitTarget(
      id: 'app',
      wsUri: 'ws://127.0.0.1:${server.port}',
      httpEndpoint: 'http://127.0.0.1:${server.port}',
      devfsName: 'must-not-be-created',
      platformReload: () async {
        reloads++;
      },
    );
    try {
      await target.connect();
      final result = await target.apply(
        unit: 'unit',
        deltaPath: 'advisory',
        deltaBytes: 0,
      );
      expect(result.ok, isTrue);
      expect(result.mode, 'serving tool reload');
      expect(reloads, 1);
      expect(methods.where((m) => m == 'reloadSources'), isEmpty);
      expect(
        methods.where((m) => m.contains('DevFS') || m == '_reloadKernel'),
        isEmpty,
      );
    } finally {
      await target.close();
      await socket?.close();
      await server.close(force: true);
    }
  });
}
