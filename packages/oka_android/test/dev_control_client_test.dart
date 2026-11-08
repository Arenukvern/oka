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

    test('replyLost when the peer resets before a reply line', () async {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(server.close);
      // Tear down on accept — the client may see this as a failed write or as
      // EOF without a JSON line (both are replyLost, not ok).
      server.listen((socket) => socket.destroy());
      final client = await DevControlClient.connect(port: server.port);
      final r = await client.requestQuit(timeout: const Duration(seconds: 5));
      expect(r.ok, isFalse);
      expect(r.replyLost || r.timedOut, isTrue);
      await client.close();
    });
  });
}
