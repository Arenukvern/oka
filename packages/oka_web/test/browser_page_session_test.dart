import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';
import 'package:test/test.dart';

void main() {
  const context = BuildContext(
    projectPath: '/tmp/page-test',
    buildDir: '/tmp/page-test/build',
    mode: BuildMode.debug,
    config: OkaConfig.empty,
  );
  const name = 'test';
  final handle = chromeSessionHandleArtifactId(name);
  final pid = chromeSessionPidArtifactId(name);
  final tab = jsonEncode({
    'id': 'owned-tab',
    'webSocketDebuggerUrl': 'ws://localhost:9222/devtools/page/owned-tab',
  });

  test(
    'borrowed process closes only created page; concurrent stop coalesces',
    () async {
      final requests = <(String, String)>[];
      var teardown = 0;
      final session = await startBrowserPageSession(
        context: context,
        appUrl: Uri.parse('http://localhost:8766/a?x=1'),
        sessionName: name,
        executeStep: (step, ctx, state) async {
          if (step is StopChromeSessionStep) teardown++;
          state[handle] = 'http://localhost:9222';
          return StepResult.success();
        },
        request: (uri, method) async {
          requests.add((uri.toString(), method));
          return method == 'PUT'
              ? tab
              : uri.path == '/json/list'
              ? '[]'
              : 'Target is closing';
        },
      );
      expect(session.ownedProcess, isFalse);
      expect(session.browserHttpUrl, Uri.parse('http://localhost:9222'));
      expect(session.pageWsUrl, contains('owned-tab'));
      await Future.wait([session.stop(), session.stop()]);
      await session.stop();
      expect(teardown, 0);
      expect(requests, [
        (
          'http://localhost:9222/json/new?http%3A%2F%2Flocalhost%3A8766%2Fa%3Fx%3D1',
          'PUT',
        ),
        ('http://localhost:9222/json/close/owned-tab', 'GET'),
        ('http://localhost:9222/json/list', 'GET'),
      ]);
    },
  );

  test(
    'failed tab close still tears down owned process and reports error',
    () async {
      var teardown = 0;
      final session = await startBrowserPageSession(
        context: context,
        appUrl: Uri.parse('http://localhost/'),
        sessionName: name,
        executeStep: (step, ctx, state) async {
          if (step is StopChromeSessionStep) teardown++;
          state[handle] = 'http://localhost:9222';
          state[pid] = 123;
          return StepResult.success();
        },
        request: (uri, method) async {
          if (method == 'GET') throw StateError('close failed');
          return tab;
        },
      );
      expect(session.ownedProcess, isTrue);
      await expectLater(session.stop(), throwsStateError);
      await expectLater(session.stop(), throwsStateError);
      expect(teardown, 1);
    },
  );

  test('stop waits for page disappearance without replaying close', () async {
    var closes = 0;
    var observations = 0;
    final session = await startBrowserPageSession(
      context: context,
      appUrl: Uri.parse('http://localhost/'),
      sessionName: name,
      executeStep: (step, ctx, state) async {
        state[handle] = 'http://localhost:9222';
        return StepResult.success();
      },
      request: (uri, method) async {
        if (method == 'PUT') return tab;
        if (uri.path == '/json/list') {
          observations++;
          return observations == 1 ? '[{"id":"owned-tab"}]' : '[]';
        }
        closes++;
        return 'Target is closing';
      },
    );
    await session.stop();
    expect(closes, 1);
    expect(observations, 2);
  });

  test(
    'unobserved close is bounded, retained as unknown, and never replayed',
    () async {
      var closes = 0;
      var observations = 0;
      final session = await startBrowserPageSession(
        context: context,
        appUrl: Uri.parse('http://localhost/'),
        sessionName: name,
        stopTimeout: const Duration(milliseconds: 20),
        executeStep: (step, ctx, state) async {
          state[handle] = 'http://localhost:9222';
          return StepResult.success();
        },
        request: (uri, method) async {
          if (method == 'PUT') return tab;
          if (uri.path == '/json/list') {
            observations++;
            return '[{"id":"owned-tab"}]';
          }
          closes++;
          return 'Target is closing';
        },
      );
      await expectLater(session.stop(), throwsStateError);
      final observed = observations;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(session.stop(), throwsStateError);
      expect(closes, 1);
      expect(
        observations,
        observed,
        reason: 'Timed-out observation loop must terminate',
      );
    },
  );

  test('malformed websocket closes known tab and owned process', () async {
    var closed = false;
    var teardown = 0;
    await expectLater(
      startBrowserPageSession(
        context: context,
        appUrl: Uri.parse('http://localhost/'),
        sessionName: name,
        executeStep: (step, ctx, state) async {
          if (step is StopChromeSessionStep) teardown++;
          state[handle] = 'http://localhost:9222';
          state[pid] = 123;
          return StepResult.success();
        },
        request: (uri, method) async {
          if (method == 'GET') {
            closed = true;
            return uri.path == '/json/list' ? '[]' : 'closing';
          }
          return '{"id":"owned-tab","webSocketDebuggerUrl":"invalid"}';
        },
      ),
      throwsStateError,
    );
    expect(closed, isTrue);
    expect(teardown, 1);
  });

  test('partial launch failure uses recorded ownership for cleanup', () async {
    var teardown = 0;
    await expectLater(
      startBrowserPageSession(
        context: context,
        appUrl: Uri.parse('http://localhost/'),
        sessionName: name,
        executeStep: (step, ctx, state) async {
          if (step is StopChromeSessionStep) {
            teardown++;
            return StepResult.success();
          }
          state[pid] = 123;
          return StepResult.failure('boot failed');
        },
        request: (_, _) async => throw StateError('no tab request expected'),
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'boot failed'),
      ),
    );
    expect(teardown, 1);
  });

  test('stalled HTTP body is bounded and tears down owned process', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final connections = <HttpResponse>[];
    server.listen((request) {
      request.response.write('{');
      connections.add(request.response);
    });
    var teardown = 0;
    try {
      await expectLater(
        startBrowserPageSession(
          context: context,
          appUrl: Uri.parse('http://localhost/'),
          sessionName: name,
          requestTimeout: const Duration(milliseconds: 100),
          executeStep: (step, ctx, state) async {
            if (step is StopChromeSessionStep) teardown++;
            state[handle] = 'http://127.0.0.1:${server.port}';
            state[pid] = 123;
            return StepResult.success();
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(teardown, 1);
    } finally {
      for (final connection in connections) {
        await connection.close();
      }
      await server.close(force: true);
    }
  });

  test(
    'teardown timeout reports unknown outcome, never claims stopped',
    () async {
      final session = await startBrowserPageSession(
        context: context,
        appUrl: Uri.parse('http://localhost/'),
        sessionName: name,
        stopTimeout: const Duration(milliseconds: 20),
        executeStep: (step, ctx, state) async {
          if (step is StopChromeSessionStep) {
            return Completer<StepResult>().future;
          }
          state[handle] = 'http://localhost:9222';
          state[pid] = 123;
          return StepResult.success();
        },
        request: (uri, method) async => method == 'PUT'
            ? tab
            : uri.path == '/json/list'
            ? '[]'
            : 'closing',
      );
      await expectLater(
        session.stop(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TimeoutException'),
          ),
        ),
      );
    },
  );
}
