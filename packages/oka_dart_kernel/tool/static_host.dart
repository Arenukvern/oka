/// A dumb static host: one directory over HTTP, with a JSON-line request
/// log. The air channel is materializable on any dumb host (ADR-0037 §2);
/// this is the local stand-in for that host — and the transfer-evidence
/// recorder for the web verify rung (which artifacts a client actually
/// fetched).
///
///   dart tool/static_host.dart --root <dir> --port <n> [--log <file>]
///
/// Also importable: [startStaticServer] for drivers that own the arc.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Serves [root] on 127.0.0.1:[port]; every request appends
/// `{"path":…,"status":…}` to [logPath] when given. Returns the bound
/// server — callers own `close()`.
Future<HttpServer> startStaticServer({
  required String root,
  required int port,
  String? logPath,
}) async {
  final logFile = logPath == null ? null : File(logPath);
  final server = await HttpServer.bind('127.0.0.1', port);
  unawaited(server.forEach((request) async {
    final path = request.uri.path == '/' ? '/index.html' : request.uri.path;
    final file = File('$root$path');
    final status = file.existsSync() ? 200 : 404;
    // Status and content type MUST precede the body: headers flush on
    // the first bytes written.
    request.response.statusCode = status;
    if (status == 200) {
      request.response.headers.contentType = _contentType(path);
      await request.response.addStream(file.openRead());
    }
    await request.response.close();
    if (logFile != null) {
      logFile.writeAsStringSync(
          '${jsonEncode({'path': path, 'status': status})}\n',
          mode: FileMode.append);
    }
  }));
  return server;
}

ContentType _contentType(String path) {
  if (path.endsWith('.html')) return ContentType.html;
  if (path.endsWith('.json')) return ContentType.json;
  if (path.endsWith('.js') || path.endsWith('.mjs')) {
    return ContentType('application', 'javascript');
  }
  if (path.endsWith('.css')) return ContentType('text', 'css');
  if (path.endsWith('.wasm')) return ContentType('application', 'wasm');
  return ContentType.binary;
}

Future<void> main(List<String> args) async {
  String? root;
  var port = 8080;
  String? log;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--root':
        root = args[++i];
      case '--port':
        port = int.parse(args[++i]);
      case '--log':
        log = args[++i];
      default:
        stderr.writeln('usage: static_host --root <dir> --port <n> '
            '[--log <file>]');
        exitCode = 2;
        return;
    }
  }
  if (root == null || !Directory(root).existsSync()) {
    stderr.writeln('static host: --root directory missing');
    exitCode = 2;
    return;
  }
  final server = await startStaticServer(
      root: Directory(root).absolute.path, port: port, logPath: log);
  // A log file is the handshake signal for gates: it exists only after
  // the server is bound and serving.
  if (log != null) File(log).writeAsStringSync('');
  // ignore: avoid_print
  print('static host: serving $root on http://127.0.0.1:$port');
  await Completer<void>().future; // serve until killed
}
