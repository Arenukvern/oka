// Shared attach daemon stdio fixture (ADR-0011 H3). Used by repo-root and
// package tests — keep here so `packages/oka_android` tests are standalone.
import 'dart:async';
import 'dart:convert';

import 'package:oka_android/oka_android.dart';

/// Scripted single-element-JSON-array daemon: records sent command lines,
/// emits fixture stdout, completes a fake exit code.
class FakeDaemonTransport implements DaemonTransport {
  final _stdout = StreamController<List<int>>.broadcast();
  final _exit = Completer<int>();
  final sent = <String>[];
  final killed = <bool>[];

  Object? Function(String method)? respondTo;
  Object? Function(String method)? respondErrorTo;
  final Set<String> silentMethods = {};
  bool emitAppStopEventOnStop = true;

  void emit(String line) => _stdout.add(utf8.encode('$line\n'));

  void emitChunk(List<String> lines) =>
      _stdout.add(utf8.encode('${lines.join('\n')}\n'));

  void emitEvent(
    String name, [
    Map<String, Object?> params = const {},
  ]) => emit(
    jsonEncode([
      {'event': name, 'params': params},
    ]),
  );

  void emitStartup() {
    emit(
      jsonEncode([
        {
          'event': 'daemon.connected',
          'params': {'version': '0.6.1'},
        },
      ]),
    );
    emitEvent('app.start', {
      'appId': 'com.example.example',
      'launchMode': 'attach',
      'mode': 'debug',
    });
    emitEvent('app.debugPort', {
      'port': 65462,
      'wsUri': 'ws://127.0.0.1:65462/XZgHLBJKpIA=/ws',
    });
    emitEvent('app.progress', {
      'progressId': 'devFS.update',
      'message': 'Syncing files to device sdk gphone64 arm64...',
    });
    emitEvent('app.started', {'appId': 'com.example.example'});
  }

  void respond(int id, {Object? result, Object? error}) =>
      emit(
        jsonEncode([
          {'id': id, 'result': ?result, 'error': ?error},
        ]),
      );

  void exitWith(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void writeLine(String line) {
    sent.add(line);
    final decoded = jsonDecode(line) as List;
    final id = (decoded.single as Map)['id'] as int;
    final method = (decoded.single as Map)['method'] as String;
    if (silentMethods.contains(method)) return;
    final errorResponder = respondErrorTo;
    final err = errorResponder?.call(method);
    if (err != null) {
      respond(id, error: err);
    } else {
      final responder = respondTo;
      if (responder != null) respond(id, result: responder(method));
    }
    if (method == 'app.stop' && emitAppStopEventOnStop) {
      emitEvent('app.stop');
    }
    if (method == 'daemon.shutdown' && !_exit.isCompleted) {
      exitWith(0);
    }
  }

  @override
  bool kill() {
    killed.add(true);
    exitWith(0);
    return true;
  }
}
