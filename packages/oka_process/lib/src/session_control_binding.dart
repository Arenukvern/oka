import 'dart:io';

import 'package:meta/meta.dart';

/// Raised when the control-socket directory cannot be secured (fail closed).
final class SessionControlBindException implements Exception {
  SessionControlBindException(this.message);

  final String message;

  @override
  String toString() => 'SessionControlBindException: $message';
}

/// Runs `chmod` on the control directory (`@visibleForTesting`).
@visibleForTesting
Future<ProcessResult> sessionControlChmodRunner(String directoryPath) =>
    Process.run('chmod', ['700', directoryPath]);

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

  static Future<SessionControlBinding> bind({
    Future<ProcessResult> Function(String directoryPath)? chmodRunner,
  }) async {
    final runChmod = chmodRunner ?? sessionControlChmodRunner;
    Directory? directory;
    ServerSocket? server;
    try {
      directory = await Directory.systemTemp.createTemp('oka-p1-');
      final chmodResult = await runChmod(directory.path);
      if (chmodResult.exitCode != 0) {
        throw SessionControlBindException(
          'control socket directory chmod 700 failed '
          '(exit ${chmodResult.exitCode})',
        );
      }
      final socketPath = '${directory.path}/control.sock';
      server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      return SessionControlBinding(
        directory: directory,
        socketPath: socketPath,
        server: server,
        firstConnection: server.first,
      );
    } on Object catch (error) {
      await _disposePartial(server: server, directory: directory);
      if (error is SessionControlBindException) rethrow;
      throw SessionControlBindException('control socket bind failed: $error');
    }
  }

  static Future<void> _disposePartial({
    ServerSocket? server,
    Directory? directory,
  }) async {
    if (server != null) {
      try {
        await server.close();
      } on Object {
        // Best-effort.
      }
    }
    if (directory != null) {
      try {
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      } on Object {
        // Best-effort.
      }
    }
  }

  Future<void> dispose() async {
    await _disposePartial(server: server, directory: directory);
  }
}
