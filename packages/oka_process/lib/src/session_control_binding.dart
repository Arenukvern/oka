import 'dart:io';

/// Host-side Unix socket for p1 owned-session control.
final class SessionControlBinding {
  SessionControlBinding({
    required this.directory,
    required this.socketPath,
    required this.server,
    required this.firstConnection,
  });

  final Directory directory;
  final String socketPath;
  final ServerSocket server;
  final Future<Socket> firstConnection;

  static Future<SessionControlBinding?> bind() async {
    try {
      final directory = await Directory.systemTemp.createTemp('oka-p1-');
      await Process.run('chmod', ['700', directory.path]);
      final socketPath = '${directory.path}/control.sock';
      final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      return SessionControlBinding(
        directory: directory,
        socketPath: socketPath,
        server: server,
        firstConnection: server.first,
      );
    } on Object {
      return null;
    }
  }

  Future<void> dispose() async {
    try {
      await server.close();
    } on Object {
      // Best-effort.
    }
    try {
      directory.deleteSync(recursive: true);
    } on Object {
      // Best-effort.
    }
  }
}
