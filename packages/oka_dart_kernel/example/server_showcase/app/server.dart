/// The showcase server: one dart:io HTTP server whose responses delegate
/// to the declared patch unit (`units/greeter.dart`).
///
/// Started by run.sh with the VM service ON — that is lane S1 (ADR-0035):
/// a JIT server oka can patch live. Three routes:
///
/// - `GET /`       greet() + process facts (pid, uptime)
/// - `GET /health` the unit-independent liveness surface (hold probe)
/// - `GET /stream` a chunked line every second — an open connection must
///                 keep flowing ACROSS a live patch (continuity proof)
import 'dart:async';
import 'dart:io';

import 'package:showcase_server/units/greeter.dart';

final started = DateTime.now();
var ticks = 0;

String status() =>
    '${greet()} pid=$pid uptime=${DateTime.now().difference(started).inSeconds}s';

Future<void> main() async {
  final server = await HttpServer.bind('127.0.0.1', 8251);
  // ignore: avoid_print
  print('server: listening on ${server.port} pid=$pid');
  server.listen((request) async {
    switch (request.uri.path) {
      case '/':
        request.response.write(status());
        await request.response.close();
      case '/health':
        request.response.write('ok');
        await request.response.close();
      case '/stream':
        // bufferOutput=false: the point of /stream is that bytes reach the
        // client the moment they are written.
        request.response.bufferOutput = false;
        request.response.headers.chunkedTransferEncoding = true;
        request.response.write('stream: ${greet()}\n');
        Timer.periodic(const Duration(seconds: 1), (t) {
          ticks++;
          request.response.write('stream[${t.tick}]: ${greet()}\n');
        });
      default:
        request.response.statusCode = 404;
        await request.response.close();
    }
  });
}
