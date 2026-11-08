import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  group('DevControlClient', () {
    test('quit receives ok when the server answers', () async {
      final server = await DevControlServer.start(
        info: const DevControlSessionInfo(
          deviceId: 'emu',
          target: 'lib/main.dart',
          mode: 'debug',
        ),
        onCommand: (_) {},
      );
      addTearDown(server.close);
      final client = await DevControlClient.connect(port: server.port);
      final r = await client.requestQuit();
      expect(r.ok, isTrue);
      expect(
        (r.response!['result'] as Map<String, Object?>?)?['session'],
        'quit_accepted',
      );
      await client.close();
    });

    test('replyLost after flush when peer drops without a JSON line', () async {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(server.close);
      server.listen((socket) {
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((_) => socket.destroy());
      });
      final client = await DevControlClient.connect(port: server.port);
      final r = await client.requestQuit(timeout: const Duration(seconds: 2));
      expect(r.commandFlushed, isTrue);
      expect(r.replyLost, isTrue);
      expect(r.timedOut, isFalse);
      expect(r.ok, isFalse);
      await client.close();
    });
  });
}
