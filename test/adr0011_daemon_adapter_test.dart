// ADR-0011 H3 — flutter_tools daemon adapter against scripted stdio
// fixtures (no real flutter binary, no device; the live e2e tier is
// recorded in PHASE_CHECKLIST + hot_reload_plan.md).
import 'dart:async';
import 'dart:convert';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

/// Scripted single-element-JSON-array daemon: records sent command lines,
/// emits fixture stdout, completes a fake exit code.
class FakeDaemonTransport implements DaemonTransport {
  final _stdout = StreamController<List<int>>.broadcast();
  final _exit = Completer<int>();
  final sent = <String>[];
  final killed = <bool>[];

  /// Auto-responder: when non-null, every sent command gets this result
  /// echoed back with the same id.
  Object? Function(String method)? respondTo;

  /// Auto-responder for **error** responses (checked before
  /// [respondTo]); e.g. `(method) => method == 'app.reload'
  ///     ? 'Observable wipe failed' : null`.
  Object? Function(String method)? respondErrorTo;

  /// Methods that never get an auto-response (simulates a daemon that
  /// stops answering — e.g. the physical-device attach-mode restart hang).
  final Set<String> silentMethods = {};

  void emit(final String line) => _stdout.add(utf8.encode('$line\n'));

  void emitEvent(
    final String name, [
    final Map<String, Object?> params = const {},
  ]) => emit(
    jsonEncode([
      {'event': name, 'params': params},
    ]),
  );

  /// Emits a full H0-style attach startup sequence.
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

  void respond(final int id, {final Object? result, final Object? error}) =>
      emit(
        jsonEncode([
          {'id': id, 'result': ?result, 'error': ?error},
        ]),
      );

  void exitWith(final int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void writeLine(final String line) {
    sent.add(line);
    // Auto-respond with the daemon's response shape (id echo) when a
    // responder is installed; otherwise the test replies manually.
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
  }

  @override
  bool kill() {
    killed.add(true);
    exitWith(0);
    return true;
  }
}

void main() {
  group('flutterAttachMachineArgs (pure argv)', () {
    test('attach --machine -d <id>', () {
      expect(flutterAttachMachineArgs(deviceId: 'emulator-5554'), [
        'attach',
        '--machine',
        '-d',
        'emulator-5554',
      ]);
    });
  });

  group('event parsing (single-element JSON arrays; feature-detect)', () {
    test('parses the pinned H0 event sequence', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      final events = <String>[];
      final sub = adapter.events.listen((final e) => events.add(e.event));
      t.emitStartup();
      await Future<void>.delayed(Duration.zero);
      expect(
        events,
        containsAllInOrder([
          'daemon.connected',
          'app.start',
          'app.debugPort',
          'app.progress',
          'app.started',
        ]),
      );
      expect(adapter.daemonVersion, '0.6.1');
      expect(adapter.appStartReceived, isTrue);
      expect(adapter.wsUri, 'ws://127.0.0.1:65462/XZgHLBJKpIA=/ws');
      await sub.cancel();
      adapter.dispose();
    });

    test('bare JSON objects are tolerated (feature-detect)', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      final events = <DaemonEvent>[];
      final sub = adapter.events.listen(events.add);
      t.emit(jsonEncode({'event': 'app.started'}));
      await Future<void>.delayed(Duration.zero);
      expect(events.single.event, 'app.started');
      await sub.cancel();
      adapter.dispose();
    });

    test('chatter lines and arrays of scalars are ignored', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      final events = <DaemonEvent>[];
      final sub = adapter.events.listen(events.add);
      t.emit('Waiting for a connection from Flutter on sdk gphone64 arm64...');
      t.emit(jsonEncode([1, 2, 3]));
      t.emit('');
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      expect(adapter.appStartReceived, isFalse);
      await sub.cancel();
      adapter.dispose();
    });

    test(
      'unknown events and unknown fields are preserved, not fatal',
      () async {
        final t = FakeDaemonTransport();
        final adapter = FlutterDaemonAdapter(transport: t);
        final events = <DaemonEvent>[];
        final sub = adapter.events.listen(events.add);
        t.emitEvent('app.futureThing', {
          'brandNewField': {'nested': true},
        });
        await Future<void>.delayed(Duration.zero);
        expect(events.single.event, 'app.futureThing');
        expect(events.single.field('brandNewField'), {'nested': true});
        await sub.cancel();
        adapter.dispose();
      },
    );
  });

  group('command gating + responses', () {
    test(
      'commands wait for app.start, then send single-element arrays',
      () async {
        final t = FakeDaemonTransport()
          ..respondTo = (final method) => const <String, Object?>{};
        final adapter = FlutterDaemonAdapter(transport: t);
        final sentFuture = adapter.reload();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(t.sent, isEmpty, reason: 'nothing before app.start');
        t.emitStartup();
        final r = await sentFuture;
        expect(r.ok, isTrue);
        expect(t.sent, hasLength(1));
        final decoded = jsonDecode(t.sent.single) as List;
        expect(decoded, hasLength(1));
        final cmd = decoded.single as Map;
        // Live-probed interface (flutter_tools 3.47.0-0.4.pre): hot
        // reload is app.restart with fullRestart: false, appId required.
        expect(cmd['method'], 'app.restart');
        expect(cmd['id'], isA<int>());
        expect(cmd['params'], {
          'appId': 'com.example.example',
          'fullRestart': false,
        });
        adapter.dispose();
      },
    );

    test('waitAppStart times out with an actionable message', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      await expectLater(
        adapter.waitAppStart(timeout: const Duration(milliseconds: 50)),
        throwsA(
          isA<DaemonException>().having(
            (final e) => e.message,
            'message',
            contains('app.start'),
          ),
        ),
      );
      adapter.dispose();
    });

    test('error responses come back typed with text', () async {
      final t = FakeDaemonTransport()
        ..respondTo = (final method) =>
            method == 'app.reload' ? null : <String, Object?>{};
      // Custom responder returning an error result is not expressible via
      // respondTo (result slot) — drive the error through a manual reply.
      t.respondTo = null;
      final adapter = FlutterDaemonAdapter(transport: t);
      t.emitStartup();
      final sentFuture = adapter.restart();
      await Future<void>.delayed(Duration.zero);
      final id =
          ((jsonDecode(t.sent.single) as List).single as Map)['id'] as int;
      t.respond(id, error: 'Observable wipe failed');
      final r = await sentFuture;
      expect(r.ok, isFalse);
      expect(r.errorText, 'Observable wipe failed');
      adapter.dispose();
    });

    test('daemon exit fails pending sends and marks exited', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      t.emitStartup();
      final sent = adapter.reload();
      await Future<void>.delayed(Duration.zero);
      // No response yet; daemon dies instead.
      t.exitWith(70);
      await expectLater(sent, throwsA(isA<DaemonException>()));
      expect(adapter.exited, isTrue);
      expect(adapter.exitCode, completion(70));
      adapter.dispose();
    });

    test('reload/restart/stop/detach/shutdown use the live-probed '
        'interface', () async {
      final sent = <Map<String, Object?>>[];
      final t = FakeDaemonTransport()
        ..respondTo = (final method) => const <String, Object?>{};
      final adapter = FlutterDaemonAdapter(transport: t);
      t.emitStartup();
      await adapter.reload();
      await adapter.restart();
      await adapter.stopApp();
      await adapter.detachApp();
      await adapter.shutdown();
      for (final line in t.sent) {
        final cmd = (jsonDecode(line) as List).single as Map;
        sent.add({
          'method': cmd['method'] as String,
          'params': (cmd['params'] as Map?)?.cast<String, Object?>() ?? {},
        });
      }
      expect(sent.map((final c) => c['method']), [
        'app.restart',
        'app.restart',
        'app.stop',
        'app.detach',
        'daemon.shutdown',
      ]);
      // Hot reload vs hot restart differ only in fullRestart.
      expect(sent[0]['params'], {
        'appId': 'com.example.example',
        'fullRestart': false,
      });
      expect(sent[1]['params'], {
        'appId': 'com.example.example',
        'fullRestart': true,
      });
      expect(sent[2]['params'], {'appId': 'com.example.example'});
      expect(sent[3]['params'], {'appId': 'com.example.example'});
      expect(sent[4]['params'], isEmpty, reason: 'daemon domain, no appId');
      adapter.dispose();
    });

    test(
      'older-layout fallback: app.restart not understood → app.reload',
      () async {
        final methods = <String>[];
        final t = FakeDaemonTransport();
        t.respondErrorTo = (method) =>
            method == 'app.restart'
                ? 'command not understood: app.restart'
                : null;
        t.respondTo = (method) {
          methods.add(method);
          return const <String, Object?>{};
        };
        final adapter = FlutterDaemonAdapter(transport: t);
        t.emitStartup();
        final r = await adapter.reload();
        expect(r.ok, isTrue);
        expect(methods, ['app.reload']);
        adapter.dispose();
      },
    );
  });
}
