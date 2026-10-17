import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

void main() {
  test(
    'serving-tool reload dispatches once and never also calls DWDS reload',
    () async {
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
      final target = WebDwdsTarget(
        id: 'app',
        wsUri: 'ws://127.0.0.1:${server.port}',
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
        final unsafe = WebDwdsTarget(
          id: 'unsafe',
          wsUri: 'ws://127.0.0.1:${server.port}',
          pidFile: '/nonexistent-no-signal-dispatch',
          signal: 'USR1',
        );
        try {
          await unsafe.connect();
          final refusal = await unsafe.apply(
            unit: 'unit',
            deltaPath: 'advisory',
            deltaBytes: 0,
          );
          expect(refusal.ok, isFalse);
          expect(refusal.error, contains('acknowledged platformReload owner'));
        } finally {
          await unsafe.close();
        }
      } finally {
        await target.close();
        await socket?.close();
        await server.close(force: true);
      }
    },
  );
}
