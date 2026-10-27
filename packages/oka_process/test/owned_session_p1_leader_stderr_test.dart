@TestOn('vm && (linux || mac-os)')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// Ensures the reference `.pl` leader matches the host first-line ready
/// contract when Perl warnings are enabled (embed strips `use warnings` only).
void main() {
  late String perl;
  late String leaderScript;

  setUpAll(() async {
    for (final path in const ['/usr/bin/perl', '/bin/perl']) {
      if (File(path).existsSync()) {
        perl = path;
        break;
      }
    }
    expect(perl, isNotEmpty, reason: 'system perl required');
    final entry = await Isolate.resolvePackageUri(
      Uri.parse('package:oka_process/oka_process.dart'),
    );
    expect(entry, isNotNull);
    final packageRoot = File.fromUri(entry!).parent.parent;
    leaderScript =
        Platform.environment['OWNED_SESSION_P1_LEADER'] ??
        '${packageRoot.path}/tool/owned_session_p1_leader.pl';
    expect(File(leaderScript).existsSync(), isTrue);
  });

  test('first stderr line is ready under use warnings', () async {
    final binding = await _bindControl();
    addTearDown(binding.dispose);
    const marker = 'p1_stderr_ready_first';
    final leader = await Process.start(perl, [
      '-w',
      leaderScript,
      '--protocol',
      '1',
      '--mode',
      'owned',
      '--marker',
      marker,
      '--control',
      binding.socketPath,
      '--',
      'sleep',
      '3600',
    ]);
    addTearDown(() async {
      leader.kill(ProcessSignal.sigkill);
      await leader.exitCode.timeout(const Duration(seconds: 2));
    });
    final firstStderrLine = await _firstStderrLine(leader.stderr);
    expect(
      firstStderrLine,
      matches(RegExp('^$marker:ready:\\d+:p1:perl\$')),
      reason:
          'host must parse ready as the first stderr line (no Perl warnings)',
    );
    final client = await binding.server.first.timeout(
      const Duration(seconds: 5),
    );
    client.destroy();
  });
}

Future<String> _firstStderrLine(Stream<List<int>> stderr) {
  final buffer = <int>[];
  final done = Completer<String>();
  late final StreamSubscription<List<int>> sub;
  sub = stderr.listen(
    (chunk) {
      buffer.addAll(chunk);
      final index = buffer.indexOf(10);
      if (index >= 0 && !done.isCompleted) {
        done.complete(
          utf8.decode(buffer.sublist(0, index), allowMalformed: true),
        );
        unawaited(sub.cancel());
      }
    },
    onDone: () {
      if (!done.isCompleted) {
        done.completeError(StateError('stderr closed before first line'));
      }
    },
    onError: done.completeError,
  );
  return done.future.timeout(const Duration(seconds: 5));
}

final class _ControlBinding {
  _ControlBinding({
    required this.directory,
    required this.socketPath,
    required this.server,
  });

  final Directory directory;
  final String socketPath;
  final ServerSocket server;

  static Future<_ControlBinding> bind() async {
    final directory = await Directory.systemTemp.createTemp('p1-stderr-');
    await Process.run('chmod', ['700', directory.path]);
    final socketPath = '${directory.path}/control.sock';
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    return _ControlBinding(
      directory: directory,
      socketPath: socketPath,
      server: server,
    );
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

Future<_ControlBinding> _bindControl() => _ControlBinding.bind();
