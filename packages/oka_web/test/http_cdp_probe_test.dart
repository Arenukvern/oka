import 'dart:async';
import 'dart:io';
import 'package:oka_web/oka_web.dart';
import 'package:test/test.dart';

void main() {
  test(
    'readiness deadline includes a response body that never completes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.write('partial');
        unawaited(request.response.flush().catchError((Object _) {}));
      });
      try {
        final result = await httpCdpProbe(
          Uri.parse('http://127.0.0.1:${server.port}/json/version'),
          timeout: const Duration(milliseconds: 100),
        ).timeout(const Duration(seconds: 2));
        expect(result, isNull);
      } finally {
        await server.close(force: true);
      }
    },
  );
  test('readiness returns a complete body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write('{"Browser":"Chrome/155"}');
      await request.response.close();
    });
    try {
      expect(
        await httpCdpProbe(
          Uri.parse('http://127.0.0.1:${server.port}/json/version'),
        ),
        '{"Browser":"Chrome/155"}',
      );
    } finally {
      await server.close(force: true);
    }
  });
}
