// ADR-0011 roadmap Now — the `oka dev` delegation channel: the loopback
// TCP JSON-lines control server against real loopback sockets and the
// scripted-fake DevSession machinery (no real flutter, no device), plus
// the spec-v2 runner-session discovery-file lifecycle (write at
// session.ready incl. the `runner` field, both discovery files cleared on
// session exit, the toolkit's `.flutter_mcp/state.json` untouched).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'adr0011_daemon_adapter_test.dart' show FakeDaemonTransport;

const _sessionJson = {
  'schema': 1,
  'oka_version': '0.0.0-test',
  'recorded_at': '2026-09-08T00:00:00.000Z',
  'flutter_sdk_path': '/fake/flutter-sdk',
  'engine_revision': 'f88005a259ba379c2c1156178aa1870936be7b7f',
  'target_file': 'lib/main.dart',
  'build_mode': 'debug',
  'dart_defines': <String, String>{},
  'application_id': 'com.example.example',
  'abis': ['arm64-v8a'],
  'apk_path': '.oka_cache/build/debug/app-debug.apk',
  'flavor': '',
  'track_widget_creation': true,
};

RunSession get _session => RunSession.fromJson(_sessionJson);

/// One wired delegation channel: a scripted-fake [DevSession] whose
/// results feed a real loopback [DevControlServer] through the same hooks
/// `oka dev` uses (commands in via the shared control stream, outcomes in
/// via `onResult`, the runner-session file written at `session.ready`).
class _Harness {
  _Harness._(
    this.server,
    this.transport,
    this.control,
    this.projectDir,
    this.lines,
  );

  final DevControlServer server;
  final FakeDaemonTransport transport;
  final StreamController<DevControlCommand> control;
  final Directory projectDir;
  final List<String> lines;
  final Completer<void> _ended = Completer<void>();
  /// Completed when the session reaches `session.ready` (the discovery
  /// hook fired).
  final Completer<void> ready = Completer<void>();
  late final DevSession session;

  static Future<_Harness> start({
    final int port = 0,
    final Set<String> silentMethods = const {},
    final Duration reloadTimeout = const Duration(seconds: 5),
    final Duration restartTimeout = const Duration(seconds: 5),
    final Duration stopTimeout = const Duration(seconds: 5),
  }) async {
    final projectDir = await Directory.systemTemp.createTemp('oka_control');
    final transport = FakeDaemonTransport()
      ..silentMethods.addAll(silentMethods)
      ..respondTo = (final _) => const <String, Object?>{};
    final control = StreamController<DevControlCommand>.broadcast();
    final server = await DevControlServer.start(
      port: port,
      info: const DevControlSessionInfo(
        deviceId: 'emulator-5554',
        target: 'lib/main.dart',
        mode: 'debug',
      ),
      onCommand: control.add,
      reloadTimeout: reloadTimeout,
      restartTimeout: restartTimeout,
      stopTimeout: stopTimeout,
    );
    final h = _Harness._(
      server,
      transport,
      control,
      projectDir,
      <String>[],
    );
    h.session = DevSession(
      adapter: FlutterDaemonAdapter(transport: transport),
      session: _session,
      deviceId: 'emulator-5554',
      json: true,
      write: h.lines.add,
      commands: control.stream,
      startupTimeout: const Duration(seconds: 5),
      onReady: () {
        if (!h.ready.isCompleted) h.ready.complete();
        unawaited(
          writeRunnerSessionFile(
            projectDir.path,
            vmServiceUri: 'ws://127.0.0.1:65462/XZgHLBJKpIA=/ws',
            controlPort: server.port,
            deviceId: 'emulator-5554',
          ),
        );
      },
      onResult: server.handleSessionResult,
    );
    transport.emitStartup();
    unawaited(
      h.session.run().then(
        (_) {
          if (!h._ended.isCompleted) h._ended.complete();
        },
        onError: (final Object e) {
          if (!h._ended.isCompleted) h._ended.completeError(e);
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return h;
  }

  Future<void> waitReady() => ready.future;

  /// Ends the session like `oka dev` does on every exit path: closes the
  /// server and clears both discovery files.
  Future<void> teardown() async {
    transport.exitWith(0);
    await control.close();
    await server.close();
    await clearVmUriFile(projectDir.path);
    await clearRunnerSessionFile(projectDir.path);
  }
}

/// A connected control client that collects JSON-line responses.
class _ControlClient {
  _ControlClient(this._socket) {
    _sub = _socket
        .map(utf8.decode)
        .transform(const LineSplitter())
        .listen(_lines.add, onDone: () => _done.complete());
  }

  final Socket _socket;
  late final StreamSubscription<void> _sub;
  final _lines = <String>[];
  final _done = Completer<void>();

  Future<Map<String, Object?>> request(
    final Map<String, Object?> request,
  ) async {
    _lines.clear();
    _socket.write('${jsonEncode(request)}\n');
    while (_lines.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return jsonDecode(_lines.first) as Map<String, Object?>;
  }

  Future<void> close() async {
    await _sub.cancel();
    _socket.destroy();
  }

  Future<void> get eof => _done.future;
}

void main() {
  group('DevControlServer (real loopback sockets, scripted fake session)', () {
    test('reload answers with the real daemon outcome', () async {
      final h = await _Harness.start();
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final r = await client.request({'id': 1, 'method': 'reload'});
      expect(r['id'], 1);
      expect(r['ok'], isTrue);
      expect(r['result'], <String, Object?>{});

      final methods =
          h.transport.sent
              .map(
                (final l) =>
                    ((jsonDecode(l) as List).single
                        as Map)['method'] as String,
              )
              .toList();
      expect(methods, contains('app.restart'));
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });

    test('restart with silent app.restart → fallback response, then EOF',
        () async {
      final h = await _Harness.start(silentMethods: {'app.restart'});
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final responseFuture = client.request({'id': 7, 'method': 'restart'});
      // The physical-device failure mode: app.restart never answers; the
      // app just stops mid-restart → the session takes the fallback.
      Future<void>.delayed(const Duration(milliseconds: 50)).then(
        (_) => h.transport.emitEvent('app.stop'),
      );
      final r = await responseFuture.timeout(const Duration(seconds: 5));
      expect(r['id'], 7);
      expect(r['ok'], isFalse);
      expect(r['fallback'], isTrue, reason: '$r');
      expect((r['error'] as String), contains('re-attaching'));

      // The fallback ends the session (relaunch + re-attach); when the
      // owner closes the server the client must observe EOF (it re-reads
      // runner-session.json for the new session).
      await h.teardown();
      await client.eof.timeout(const Duration(seconds: 5));
      h.projectDir.deleteSync(recursive: true);
    });

    test('restart success answers ok with no fallback', () async {
      final h = await _Harness.start();
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final r = await client.request({'id': 2, 'method': 'restart'});
      expect(r['id'], 2);
      expect(r['ok'], isTrue);
      expect(r.containsKey('fallback'), isFalse);
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });

    test('stop stops the app and answers ok; the session keeps running',
        () async {
      final h = await _Harness.start();
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final r = await client.request({'id': 3, 'method': 'stop'});
      expect(r['ok'], isTrue);
      final methods =
          h.transport.sent
              .map(
                (final l) =>
                    ((jsonDecode(l) as List).single
                        as Map)['method'] as String,
              )
              .toList();
      expect(methods, contains('app.stop'));
      // Session still alive after stop → a follow-up reload still answers.
      final r2 = await client.request({'id': 4, 'method': 'reload'});
      expect(r2['ok'], isTrue);
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });

    test('status answers from session metadata (no daemon round-trip)',
        () async {
      final h = await _Harness.start();
      final sentBefore = h.transport.sent.length;
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final r = await client.request({'id': 5, 'method': 'status'});
      expect(r['ok'], isTrue);
      expect(r['result'], {
        'session': 'ready',
        'device': 'emulator-5554',
        'target': 'lib/main.dart',
        'mode': 'debug',
      });
      expect(
        h.transport.sent.length,
        sentBefore,
        reason: 'status must not touch the daemon',
      );
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });

    test('malformed JSON → per-id error, connection stays open', () async {
      final h = await _Harness.start();
      final socket = await Socket.connect('127.0.0.1', h.server.port);
      final client = _ControlClient(socket);
      socket.write('this is not json\n');
      while (client._lines.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final err =
          jsonDecode(client._lines.first) as Map<String, Object?>;
      expect(err['ok'], isFalse);
      expect(err['error'], contains('Malformed'));
      // Same connection still works — no reset.
      final r = await client.request({'id': 9, 'method': 'status'});
      expect(r['id'], 9);
      expect(r['ok'], isTrue);
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });

    test('unknown method → per-id error, connection stays open', () async {
      final h = await _Harness.start();
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final r = await client.request({'id': 11, 'method': 'frobnicate'});
      expect(r['id'], 11);
      expect(r['ok'], isFalse);
      expect(r['error'], contains("Unknown method 'frobnicate'"));
      expect(r['error'], contains('status'));
      final r2 = await client.request({'id': 12, 'method': 'status'});
      expect(r2['ok'], isTrue, reason: 'connection stays open after errors');
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });

    test('non-int id and missing method get per-id errors', () async {
      final h = await _Harness.start();
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final r = await client.request({'id': 1});
      expect(r['id'], 1);
      expect(r['ok'], isFalse);
      expect(r['error'], contains('method'));
      final r2 = await client.request({'id': 'x', 'method': 3});
      expect(r2['ok'], isFalse);
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });

    test('multiple sequential clients are served; disconnects are handled',
        () async {
      final h = await _Harness.start();
      final first = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final r1 = await first.request({'id': 1, 'method': 'status'});
      expect(r1['ok'], isTrue);
      await first.close();
      // Server survives the disconnect and serves the next client.
      final second = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final r2 = await second.request({'id': 2, 'method': 'reload'});
      expect(r2['id'], 2);
      expect(r2['ok'], isTrue);
      await second.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });

    test('timeout → bounded error response naming the session check',
        () async {
      final h = await _Harness.start(
        // app.restart silent → reload.result never fires.
        silentMethods: {'app.restart'},
        reloadTimeout: const Duration(milliseconds: 60),
      );
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      final r = await client
          .request({'id': 21, 'method': 'reload'})
          .timeout(const Duration(seconds: 5));
      expect(r['id'], 21);
      expect(r['ok'], isFalse);
      expect((r['error'] as String), contains('no result within'));
      expect((r['error'] as String), contains('runner-session.json'));
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });

    test('port is discoverable via runner-session.json '
        '(port-from-runner-session)', () async {
      final h = await _Harness.start();
      // runner-session.json was written at session.ready with the chosen
      // (ephemeral) port — a reader must be able to connect from it alone.
      final discovery = readRunnerSessionFile(h.projectDir.path);
      expect(discovery, isNotNull);
      expect(discovery!.controlPort, h.server.port);
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', discovery.controlPort),
      );
      final r = await client.request({'id': 1, 'method': 'status'});
      expect(r['ok'], isTrue);
      expect((r['result'] as Map)['device'], discovery.deviceId);
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });
  });

  group('runner-session.json discovery file (spec v2)', () {
    test('write + read round-trip carries every spec field incl. runner',
        () async {
      final tmp = await Directory.systemTemp.createTemp('oka_runner_session');
      addTearDown(() => tmp.delete(recursive: true));
      expect(readRunnerSessionFile(tmp.path), isNull);
      await writeRunnerSessionFile(
        tmp.path,
        vmServiceUri: 'ws://127.0.0.1:65250/TOKEN/ws',
        controlPort: 59871,
        deviceId: 'emulator-5554',
        processPid: 12345,
        startedAt: DateTime.parse('2026-09-08T00:00:00.000Z'),
      );
      // Spec v2 location: <project>/.flutter_mcp/runner-session.json —
      // the sibling of the toolkit's state file, NOT .oka_cache.
      final f = File(runnerSessionFilePath(tmp.path));
      expect(f.path, p.join(tmp.path, '.flutter_mcp', 'runner-session.json'));
      expect(f.existsSync(), isTrue);
      final d = readRunnerSessionFile(tmp.path)!;
      expect(d.vmServiceUri, 'ws://127.0.0.1:65250/TOKEN/ws');
      expect(d.controlPort, 59871);
      expect(d.deviceId, 'emulator-5554');
      expect(d.pid, 12345);
      expect(d.startedAt.toIso8601String(), '2026-09-08T00:00:00.000Z');
      final raw = jsonDecode(f.readAsStringSync()) as Map;
      expect(raw['schema'], 1);
      expect(raw['runner'], 'oka-dev', reason: 'spec v2 display metadata');
      expect(raw['vm_service_uri'], 'ws://127.0.0.1:65250/TOKEN/ws');
      expect(raw['control_port'], 59871);
      expect(raw['device_id'], 'emulator-5554');
      expect(raw['pid'], 12345);
      expect(raw['started_at'], '2026-09-08T00:00:00.000Z');
      await clearRunnerSessionFile(tmp.path);
      expect(f.existsSync(), isFalse);
      // Clearing twice is fine (best-effort).
      await clearRunnerSessionFile(tmp.path);
    });

    test('a pre-existing .flutter_mcp/state.json is untouched by the write',
        () async {
      final tmp = await Directory.systemTemp.createTemp('oka_runner_session');
      addTearDown(() => tmp.delete(recursive: true));
      final mcpDir = Directory(p.join(tmp.path, '.flutter_mcp'))
        ..createSync(recursive: true);
      final stateFile = File(p.join(mcpDir.path, 'state.json'))
        ..writeAsStringSync('{"toolkit":"state"}\n');
      await writeRunnerSessionFile(
        tmp.path,
        vmServiceUri: 'ws://127.0.0.1:65250/TOKEN/ws',
        controlPort: 59871,
        deviceId: 'emulator-5554',
      );
      expect(stateFile.existsSync(), isTrue);
      expect(stateFile.readAsStringSync(), '{"toolkit":"state"}\n');
      // Clearing the runner file never removes the directory or siblings.
      await clearRunnerSessionFile(tmp.path);
      expect(mcpDir.existsSync(), isTrue);
      expect(stateFile.existsSync(), isTrue);
    });

    test('readers reject unknown schema values', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_runner_session');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File(runnerSessionFilePath(tmp.path));
      await f.parent.create(recursive: true);
      f.writeAsStringSync(
        jsonEncode({
          'schema': 2,
          'vm_service_uri': 'ws://127.0.0.1:1/x/ws',
          'control_port': 1,
          'device_id': 'd',
          'pid': 1,
          'started_at': '2026-09-08T00:00:00.000Z',
        }),
      );
      expect(
        () => readRunnerSessionFile(tmp.path),
        throwsA(
          isA<FormatException>().having(
            (final e) => e.message,
            'message',
            contains('schema'),
          ),
        ),
      );
    });

    test('incomplete files are rejected with the field list', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_runner_session');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File(runnerSessionFilePath(tmp.path));
      await f.parent.create(recursive: true);
      f.writeAsStringSync(jsonEncode({'schema': 1}));
      expect(
        () => readRunnerSessionFile(tmp.path),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('vm.uri + runner-session.json lifecycle (write on ready, both cleared '
      'on exit)', () {
    test('onReady writes the spec-v2 file; teardown clears both files; the '
        'old .oka_cache/dev/session.json path is no longer written',
        () async {
      final h = await _Harness.start();
      await h.waitReady();
      // vm.uri was written by the prepare half; simulate it here for the
      // lifecycle round-trip.
      await writeVmUriFile(h.projectDir.path, 'ws://127.0.0.1:65462/TOK/ws');
      expect(
        File(runnerSessionFilePath(h.projectDir.path)).existsSync(),
        isTrue,
        reason: 'runner-session.json is written at session.ready',
      );
      // The contract moved — the old .oka_cache/dev/session.json must not
      // come back.
      expect(
        File(p.join(h.projectDir.path, '.oka_cache', 'dev', 'session.json'))
            .existsSync(),
        isFalse,
      );
      final d = readRunnerSessionFile(h.projectDir.path)!;
      expect(d.controlPort, h.server.port);
      expect(d.deviceId, 'emulator-5554');
      expect(d.pid, greaterThan(0));
      expect(d.vmServiceUri, startsWith('ws://127.0.0.1:'));

      // Exit path: both discovery files cleared, server closed.
      await h.teardown();
      expect(File(vmUriFilePath(h.projectDir.path)).existsSync(), isFalse);
      expect(
        File(runnerSessionFilePath(h.projectDir.path)).existsSync(),
        isFalse,
      );
      h.projectDir.deleteSync(recursive: true);
    });

    test('onResult surfaces the real outcome events to the channel',
        () async {
      final h = await _Harness.start();
      final client = _ControlClient(
        await Socket.connect('127.0.0.1', h.server.port),
      );
      unawaited(client.request({'id': 1, 'method': 'reload'}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        h.lines.join('\n'),
        contains('"event":"reload.result"'),
        reason: 'the agent stream is unchanged (additive hooks only)',
      );
      unawaited(client.request({'id': 2, 'method': 'stop'}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.lines.join('\n'), contains('"event":"app.stopped"'));
      await client.close();
      await h.teardown();
      h.projectDir.deleteSync(recursive: true);
    });
  });
}
