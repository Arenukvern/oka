import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_mcp_harness/flutter_mcp_harness.dart';

typedef AttachProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

/// One compiler attachment to an externally owned running native app.
/// Detach leaves app teardown with its original owner. No app launch occurs here.
class FlutterAttachSession {
  FlutterAttachSession._(this.process, this.log);
  final Process process;
  final LogTap log;
  final List<String> _commandLines = [];
  bool _exited = false;
  Future<int>? _detaching;

  static Future<FlutterAttachSession> start({
    required String project,
    required String flutterBin,
    required Uri vmUri,
    String device = 'macos',
    List<String> extraArgs = const [],
    Duration timeout = const Duration(seconds: 60),
    void Function(String)? onLine,
    AttachProcessStarter processStarter = Process.start,
  }) async {
    final process = await processStarter(flutterBin, [
      'attach',
      '-d',
      device,
      '--debug-url',
      vmUri.toString(),
      '--debug',
      ...extraArgs,
    ], workingDirectory: project);
    final tap = LogTap();
    final session = FlutterAttachSession._(process, tap);
    void pump(Stream<List<int>> bytes) => bytes
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          tap.add(line);
          session._commandLines.add(line);
          if (session._commandLines.length > 1000) {
            session._commandLines.removeAt(0);
          }
          onLine?.call(line);
        });
    pump(process.stdout);
    pump(process.stderr);
    unawaited(
      process.exitCode.then((_) {
        session._exited = true;
        return tap.close();
      }),
    );
    try {
      await tap.waitFor(
        RegExp('Flutter run key commands|Flutter attach key commands'),
        timeout: timeout,
      );
      return session;
    } catch (_) {
      await session.detach();
      rethrow;
    }
  }

  void write(String command) {
    if (_exited) throw StateError('Flutter compiler attachment has exited');
    _commandLines.clear();
    process.stdin.writeln(command);
    // IOSink drains writes automatically. An unawaited flush binds the sink
    // temporarily and can reject a following detach command.
  }

  Future<String> waitFor(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    for (final line in _commandLines) {
      if (line.contains(pattern)) return line;
    }
    return log.stream
        .firstWhere((line) => line.contains(pattern))
        .timeout(timeout);
  }

  Future<int> detach() => _detaching ??= _detach();
  Future<int> _detach() async {
    if (_exited) return process.exitCode;
    write('d');
    try {
      return await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // Signal only this compiler process; the app is externally owned.
      process.kill();
      return process.exitCode.timeout(const Duration(seconds: 5));
    }
  }
}
