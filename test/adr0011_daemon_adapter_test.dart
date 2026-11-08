// ADR-0011 H3 — flutter_tools daemon adapter against scripted stdio
// fixtures (no real flutter binary, no device; the live e2e tier is
// recorded in PHASE_CHECKLIST + docs/archive/hot_reload_plan.mdx).
import 'dart:async';
import 'dart:convert';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

import '../packages/oka_android/test/support/fake_daemon_transport.dart';

void main() {
  group('flutterAttachMachineArgs (pure argv)', () {
    test('attach --machine -d <id>', () {
      expect(flutterAttachMachineArgs(deviceId: 'emulator-5554'), [
        'attach',
        '--machine',
        '-d',
        'emulator-5554',
      ]);
      expect(
        flutterAttachMachineArgs(
          deviceId: 'emulator-5554',
          deviceVmServicePort: 35699,
          hostVmServicePort: 34381,
        ),
        [
          'attach',
          '--machine',
          '-d',
          'emulator-5554',
          '--device-vmservice-port',
          '35699',
          '--host-vmservice-port',
          '34381',
          '--dds-port',
          '0',
        ],
      );

      expect(
        flutterAttachMachineArgs(deviceId: 'emu'),
        ['attach', '--machine', '-d', 'emu'],
      );

      expect(
        flutterAttachMachineArgs(
          deviceId: 'emu',
          deviceVmServicePort: 43239,
        ),
        [
          'attach',
          '--machine',
          '-d',
          'emu',
          '--device-vmservice-port',
          '43239',
        ],
      );

      expect(
        flutterAttachMachineArgs(
          deviceId: 'emu',
          deviceVmServicePort: 43239,
          hostVmServicePort: 36605,
          ddsPort: 39123,
        ),
        containsAll(<String>[
          '--host-vmservice-port',
          '36605',
          '--dds-port',
          '39123',
        ]),
      );
    });
  });

  group('waitForAppStarted (fail-fast)', () {
    test('app.stop before app.started returns immediately', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      t.emitEvent('daemon.connected', {'version': '0.6.1', 'pid': 1});
      t.emitEvent('app.start', {'appId': 'x', 'launchMode': 'attach'});
      await adapter.waitAppStart();
      final watch = Stopwatch()..start();
      t.emitEvent('app.stop', {'appId': 'x'});
      final failure = await adapter.waitForAppStarted(
        timeout: const Duration(seconds: 30),
      );
      expect(failure, AttachHandshakeFailure.appStopBeforeStarted);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      final ring = adapter.snapshotMachineEventRing();
      expect(
        ring.map((e) => e['event']).toList(),
        ['daemon.connected', 'app.start', 'app.stop'],
      );
      adapter.dispose();
    });

    test('app.start and app.stop same stdout chunk prechecks stop', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      t.emitChunk([
        jsonEncode([
          {
            'event': 'daemon.connected',
            'params': {'version': '0.6.1'},
          },
        ]),
        jsonEncode([
          {
            'event': 'app.start',
            'params': {'appId': 'x', 'launchMode': 'attach'},
          },
        ]),
        jsonEncode([
          {'event': 'app.stop', 'params': {'appId': 'x'}},
        ]),
      ]);
      await adapter.waitAppStart();
      final watch = Stopwatch()..start();
      final failure = await adapter.waitForAppStarted(
        timeout: const Duration(seconds: 30),
      );
      expect(failure, AttachHandshakeFailure.appStopBeforeStarted);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 50)));
      expect(adapter.stopAfterStartBeforeStarted, isTrue);
      adapter.dispose();
    });

    test('app.stop before app.start is not fatal', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      t.emitEvent('daemon.connected', {'version': '0.6.1'});
      t.emitEvent('app.stop', {'appId': 'x'});
      await Future<void>.delayed(Duration.zero);
      expect(adapter.stopAfterStartBeforeStarted, isFalse);
      expect(adapter.precheckAttachHandshakeFailure(), isNull);
      adapter.dispose();
    });

    test('mismatched appId stop before started is not fatal', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      t.emitEvent('daemon.connected', {'version': '0.6.1'});
      t.emitEvent('app.start', {'appId': 'start-a'});
      await adapter.waitAppStart();
      t.emitEvent('app.stop', {'appId': 'other-b'});
      expect(adapter.stopAfterStartBeforeStarted, isFalse);
      expect(adapter.precheckAttachHandshakeFailure(), isNull);
      adapter.dispose();
    });

    test('app.stop after app.started does not fail handshake', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      t.emitEvent('daemon.connected', {'version': '0.6.1'});
      t.emitEvent('app.start', {'appId': 'x', 'launchMode': 'attach'});
      await adapter.waitAppStart();
      t.emitEvent('app.started', {'appId': 'x'});
      t.emitEvent('app.stop', {'appId': 'x'});
      final failure = await adapter.waitForAppStarted();
      expect(failure, isNull);
      adapter.dispose();
    });
  });

  group('machine event ring', () {
    test('oversized single event is retained truncated', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      final huge = 'x' * 16 * 1024;
      t.emitEvent('app.huge', {'blob': huge});
      await Future<void>.delayed(Duration.zero);
      final ring = adapter.snapshotMachineEventRing();
      expect(ring, hasLength(1));
      expect(ring.single['event'], 'app.huge');
      expect(ring.single['paramsTruncated'], isTrue);
      expect(ring.single['params'], isA<Map<String, Object?>>());
      adapter.dispose();
    });

    test('unicode oversized event preview stays UTF-8 safe', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      final huge = '🔥${'é' * 8192}';
      t.emitEvent('app.unicode', {'text': huge});
      await Future<void>.delayed(Duration.zero);
      final ring = adapter.snapshotMachineEventRing();
      expect(ring.single['paramsTruncated'], isTrue);
      final preview = ring.single['params']! as Map<String, Object?>;
      final text = preview['preview']! as String;
      expect(utf8.decode(utf8.encode(text)), text);
      adapter.dispose();
    });

    test('total byte cap evicts oldest not the new oversized entry', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      for (var i = 0; i < 80; i++) {
        t.emitEvent('app.progress', {'i': i, 'pad': 'y' * 512});
      }
      await Future<void>.delayed(Duration.zero);
      final ring = adapter.snapshotMachineEventRing();
      expect(ring.length, lessThanOrEqualTo(64));
      expect(ring.last['event'], 'app.progress');
      final lastParams = ring.last['params'] as Map<String, Object?>?;
      expect(lastParams?['i'], 79);
      adapter.dispose();
    });
  });

  group('event parsing (single-element JSON arrays; feature-detect)', () {
    test('parses the pinned H0 event sequence', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      final events = <String>[];
      final sub = adapter.events.listen((e) => events.add(e.event));
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
          ..respondTo = (method) => const <String, Object?>{};
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
            (e) => e.message,
            'message',
            contains('app.start'),
          ),
        ),
      );
      adapter.dispose();
    });

    test('error responses come back typed with text', () async {
      final t = FakeDaemonTransport()
        ..respondTo = (method) =>
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
        ..respondTo = (method) => const <String, Object?>{};
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
      expect(sent.map((c) => c['method']), [
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
