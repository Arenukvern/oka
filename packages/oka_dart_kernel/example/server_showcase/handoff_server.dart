/// Snapshot-handoff server (lane S3, ADR-0035): one process of a server
/// that binds with SO_REUSEPORT (`shared: true`), so a NEW process (the
/// "new snapshot") can bind the same port and take traffic over while the
/// old one drains — no listener gap, no refused connections.
///
/// Label comes from OKA_HANDOFF_LABEL so v1/v2 runs of this same file play
/// the two roles of the swap.
import 'dart:io';

Future<void> main() async {
  final label = Platform.environment['OKA_HANDOFF_LABEL'] ?? 'v1';
  final server = await ServerSocket.bind(
    '127.0.0.1',
    8254,
    shared: true, // SO_REUSEPORT — the handoff seam
  );
  // ignore: avoid_print
  print('handoff[$label]: bound pid=$pid');
  server.listen((socket) async {
    socket.write('HTTP/1.1 200 OK\r\n'
        'content-length: ${'handoff: $label (pid $pid)\n'.length}\r\n'
        'connection: close\r\n\r\n'
        'handoff: $label (pid $pid)\n');
    await socket.flush();
    await socket.close();
  });
  // Graceful drain on SIGTERM: stop accepting, finish, exit.
  ProcessSignal.sigterm.watch().listen((_) {
    // ignore: avoid_print
    print('handoff[$label]: draining, closing listener');
    server.close();
  });
}
