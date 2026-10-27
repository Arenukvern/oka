@TestOn('vm && (linux || mac-os)')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// Black-box conformance for `tool/owned_session_p1_leader.pl` (doc/owned_session_p1.md).
void main() {
  group('owned session p1 conformance', () {
    late String perl;
    late String leaderScript;
    late String fixturesDir;

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
      fixturesDir = '${packageRoot.path}/test/fixtures/owned_session_p1';
      for (final name in [
        'graceful_ok.sh',
        'graceful_slow.sh',
        'graceful_fail.sh',
      ]) {
        await Process.run('chmod', ['+x', '$fixturesDir/$name']);
      }
    });

    test('owned bootstrap: ready line, marker auth, started', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'conf_marker_bootstrap';
      final stderr = <int>[];
      final leader = await Process.start(perl, [
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
        leader.kill();
        await leader.exitCode.timeout(const Duration(seconds: 2));
      });
      leader.stderr.listen(stderr.addAll);
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(
        await _readReadyLine(stderr, marker),
        matches(RegExp('^$marker:ready:\\d+:p1:perl\$')),
      );
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      client.writeln('kill');
      await client.flush();
      expect(await _expectKilledGroup(lines), 'killed-group');
      await client.close();
      await leader.exitCode.timeout(const Duration(seconds: 5));
    });

    test('exec failure reports marker:error, not exit 127 contract', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'conf_marker_exec_fail';
      final stderr = StringBuffer();
      final leader = await Process.start(perl, [
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
        '/no/such/executable/for/p1/conformance',
      ]);
      leader.stderr.transform(utf8.decoder).listen(stderr.write);
      final exitCode = await leader.exitCode.timeout(
        const Duration(seconds: 5),
      );
      expect(exitCode, isNot(127));
      expect(stderr.toString(), contains('$marker:error:exec:'));
    });

    test('direct SIGTERM to leader is ignored; group does not receive TERM', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'conf_marker_leader_term_ignore';
      final workDir = Directory.systemTemp.createTempSync('p1-leader-term-');
      final leader = await Process.start(perl, [
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
        'sh',
        '-c',
        r'trap "touch got_term" TERM; sleep 3600 & echo $! > member.pid; wait',
      ], workingDirectory: workDir.path);
      addTearDown(() async {
        leader.kill(ProcessSignal.sigkill);
        await leader.exitCode.timeout(const Duration(seconds: 2));
        if (workDir.existsSync()) {
          workDir.deleteSync(recursive: true);
        }
      });
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final memberPid = int.parse(
        File('${workDir.path}/member.pid').readAsStringSync().trim(),
      );
      expect(
        (await Process.run('kill', ['-TERM', '${leader.pid}'])).exitCode,
        0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        (await Process.run('kill', ['-0', '${leader.pid}'])).exitCode,
        0,
        reason: 'leader must ignore direct SIGTERM',
      );
      expect(
        (await Process.run('kill', ['-0', '$memberPid'])).exitCode,
        0,
        reason: 'group member must stay up when only the leader was signaled',
      );
      expect(
        File('${workDir.path}/got_term').existsSync(),
        isFalse,
        reason: 'target group must not receive SIGTERM from leader ignore',
      );
      client.writeln('kill');
      await client.flush();
      expect(await _expectKilledGroup(lines), 'killed-group');
      await client.close();
    });

    test('term forwards SIGTERM+CONT to the group', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'conf_marker_term';
      final workDir = Directory.systemTemp.createTempSync('p1-term-');
      final leader = await Process.start(perl, [
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
        'sh',
        '-c',
        r'trap "" TERM; sleep 3600 & echo $! > member.pid; wait',
      ], workingDirectory: workDir.path);
      addTearDown(() async {
        leader.kill();
        await leader.exitCode.timeout(const Duration(seconds: 2));
        if (workDir.existsSync()) {
          workDir.deleteSync(recursive: true);
        }
      });
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final memberPid = int.parse(
        File('${workDir.path}/member.pid').readAsStringSync().trim(),
      );
      client.writeln('term');
      await client.flush();
      expect(await lines.next(), 'term-forwarded');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        (await Process.run('kill', ['-0', '$memberPid'])).exitCode,
        0,
        reason: 'TERM-ignoring member stays up until KILL',
      );
      client.writeln('kill');
      await client.flush();
      expect(await _expectKilledGroup(lines), 'killed-group');
      await client.close();
    });

    test('graceful hook ok runs before term-forwarded', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'conf_marker_grace_ok';
      final leader = await Process.start(perl, [
        leaderScript,
        '--protocol',
        '1',
        '--mode',
        'owned',
        '--marker',
        marker,
        '--control',
        binding.socketPath,
        '--graceful',
        '$fixturesDir/graceful_ok.sh',
        '--graceful-timeout',
        '2',
        '--',
        'sleep',
        '3600',
      ]);
      addTearDown(() async {
        leader.kill();
        await leader.exitCode.timeout(const Duration(seconds: 2));
      });
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      client.writeln('term');
      await client.flush();
      expect(await lines.next(), 'graceful:ok');
      expect(await lines.next(), 'term-forwarded');
      client.writeln('kill');
      await client.flush();
      expect(await _expectKilledGroup(lines), 'killed-group');
      await client.close();
    });

    test('graceful hook timeout still escalates with term-forwarded', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'conf_marker_grace_slow';
      final leader = await Process.start(perl, [
        leaderScript,
        '--protocol',
        '1',
        '--mode',
        'owned',
        '--marker',
        marker,
        '--control',
        binding.socketPath,
        '--graceful',
        '$fixturesDir/graceful_slow.sh',
        '--graceful-timeout',
        '1',
        '--',
        'sleep',
        '3600',
      ]);
      addTearDown(() async {
        leader.kill();
        await leader.exitCode.timeout(const Duration(seconds: 2));
      });
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      client.writeln('term');
      await client.flush();
      expect(await lines.next(), 'graceful:timeout');
      expect(await lines.next(), 'term-forwarded');
      client.writeln('kill');
      await client.flush();
      expect(await _expectKilledGroup(lines), 'killed-group');
      await client.close();
    });

    test(
      'graceful hook failure reports graceful:fail then term-forwarded',
      () async {
        final binding = await _bindControl();
        addTearDown(() => binding.dispose());
        const marker = 'conf_marker_grace_fail';
        final leader = await Process.start(perl, [
          leaderScript,
          '--protocol',
          '1',
          '--mode',
          'owned',
          '--marker',
          marker,
          '--control',
          binding.socketPath,
          '--graceful',
          '$fixturesDir/graceful_fail.sh',
          '--',
          'sleep',
          '3600',
        ]);
        addTearDown(() async {
          leader.kill();
          await leader.exitCode.timeout(const Duration(seconds: 2));
        });
        final client = await binding.server.first.timeout(
          const Duration(seconds: 5),
        );
        final lines = _LineReader(client);
        expect(await lines.next(), marker);
        expect(await lines.next(), 'started');
        client.writeln('term');
        await client.flush();
        final graceful = await lines.next();
        expect(graceful, startsWith('graceful:fail:'));
        expect(await lines.next(), 'term-forwarded');
        client.writeln('kill');
        await client.flush();
        expect(await _expectKilledGroup(lines), 'killed-group');
        await client.close();
      },
    );

    test('back-to-back term and kill lines in one flush', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'conf_marker_back_to_back';
      final leader = await Process.start(perl, [
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
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      client.writeln('term');
      client.writeln('kill');
      await client.flush();
      expect(await lines.next(), 'term-forwarded');
      expect(await _expectKilledGroup(lines), 'killed-group');
      await client.close();
    });

    test('single syswrite term+kill (perl harness)', () async {
      final harness = '$fixturesDir/control_back_to_back.pl';
      final result = await Process.run(perl, [harness, leaderScript]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('term-forwarded'));
      expect(result.stdout, contains('killed-group'));
    });

    test('kill preempts a hung graceful hook', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'conf_marker_hook_kill';
      final leader = await Process.start(perl, [
        leaderScript,
        '--protocol',
        '1',
        '--mode',
        'owned',
        '--marker',
        marker,
        '--control',
        binding.socketPath,
        '--graceful',
        '$fixturesDir/graceful_slow.sh',
        '--graceful-timeout',
        '30',
        '--',
        'sleep',
        '3600',
      ]);
      addTearDown(() async {
        leader.kill(ProcessSignal.sigkill);
        await leader.exitCode.timeout(const Duration(seconds: 2));
      });
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      client.writeln('term');
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      client.writeln('kill');
      await client.flush();
      expect(await _expectKilledGroup(lines), 'killed-group');
      await client.close();
    });

    test(
      'host EOF during hook does not strand the group (SIGPIPE ignored)',
      () async {
        final binding = await _bindControl();
        addTearDown(() => binding.dispose());
        const marker = 'conf_marker_pipe_hook';
        final workDir = Directory.systemTemp.createTempSync('p1-pipe-');
        final leader = await Process.start(perl, [
          leaderScript,
          '--protocol',
          '1',
          '--mode',
          'owned',
          '--marker',
          marker,
          '--control',
          binding.socketPath,
          '--graceful',
          '$fixturesDir/graceful_slow.sh',
          '--graceful-timeout',
          '30',
          '--',
          'sh',
          '-c',
          r'sleep 3600 & echo $! > child.pid; wait',
        ], workingDirectory: workDir.path);
        final client = await binding.server.first.timeout(
          const Duration(seconds: 5),
        );
        final lines = _LineReader(client);
        expect(await lines.next(), marker);
        expect(await lines.next(), 'started');
        final childDeadline = DateTime.now().add(const Duration(seconds: 5));
        var childPid = 0;
        while (DateTime.now().isBefore(childDeadline)) {
          final f = File('${workDir.path}/child.pid');
          if (f.existsSync()) {
            childPid = int.parse(f.readAsStringSync().trim());
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(childPid, greaterThan(0));
        client.writeln('term');
        await client.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await client.close();
        await leader.exitCode.timeout(const Duration(seconds: 5));
        expect(
          (await Process.run('kill', ['-0', '$childPid'])).exitCode,
          isNot(0),
          reason: 'group must die even when host vanishes during hook',
        );
        addTearDown(() {
          if (workDir.existsSync()) workDir.deleteSync(recursive: true);
        });
      },
    );

    test('refuses bad protocol version on stderr', () async {
      final stderr = StringBuffer();
      final leader = await Process.start(perl, [
        leaderScript,
        '--protocol',
        '2',
        '--mode',
        'owned',
        '--marker',
        'm_proto',
        '--control',
        '/no/such.sock',
        '--',
        'true',
      ]);
      leader.stderr.transform(utf8.decoder).listen(stderr.write);
      final code = await leader.exitCode.timeout(const Duration(seconds: 5));
      expect(code, isNot(0));
      expect(stderr.toString(), contains('m_proto:error:protocol:'));
    });

    test('refuses --mode single on the owned leader', () async {
      final stderr = StringBuffer();
      final leader = await Process.start(perl, [
        leaderScript,
        '--protocol',
        '1',
        '--mode',
        'single',
        '--marker',
        'm_mode',
        '--control',
        '/no/such.sock',
        '--',
        'true',
      ]);
      leader.stderr.transform(utf8.decoder).listen(stderr.write);
      await leader.exitCode.timeout(const Duration(seconds: 5));
      expect(stderr.toString(), contains('m_mode:error:mode:'));
    });

    test('refuses unknown flags', () async {
      final stderr = StringBuffer();
      final leader = await Process.start(perl, [
        leaderScript,
        '--protocol',
        '1',
        '--mode',
        'owned',
        '--marker',
        'm_flag',
        '--future-flag',
        'value',
        '--control',
        '/no/such.sock',
        '--',
        'true',
      ]);
      leader.stderr.transform(utf8.decoder).listen(stderr.write);
      await leader.exitCode.timeout(const Duration(seconds: 5));
      expect(stderr.toString(), contains('m_flag:error:args:unknown-flag:'));
    });

    test('refuses fractional --graceful-timeout', () async {
      final stderr = StringBuffer();
      final leader = await Process.start(perl, [
        leaderScript,
        '--protocol',
        '1',
        '--mode',
        'owned',
        '--marker',
        'm_frac',
        '--graceful-timeout',
        '0.5',
        '--control',
        '/no/such.sock',
        '--',
        'true',
      ]);
      leader.stderr.transform(utf8.decoder).listen(stderr.write);
      await leader.exitCode.timeout(const Duration(seconds: 5));
      expect(stderr.toString(), contains('m_frac:error:args:graceful-timeout'));
    });

    test(
      'unknown control commands are ignored until a valid command',
      () async {
        final binding = await _bindControl();
        addTearDown(() => binding.dispose());
        const marker = 'm_unknown_cmd';
        final leader = await Process.start(perl, [
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
        final client = await binding.server.first.timeout(
          const Duration(seconds: 5),
        );
        final lines = _LineReader(client);
        expect(await lines.next(), marker);
        expect(await lines.next(), 'started');
        client.writeln('not-a-command');
        await client.flush();
        client.writeln('kill');
        await client.flush();
        expect(await _expectKilledGroup(lines), 'killed-group');
        await client.close();
      },
    );

    test('exit: and settle returns settled with clean exit code', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'm_settle';
      final leader = await Process.start(perl, [
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
        'true',
      ]);
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      expect(await lines.next(), startsWith('exit:'));
      client.writeln('settle');
      await client.flush();
      expect(await lines.next(), 'settled');
      await client.close();
      expect(await leader.exitCode.timeout(const Duration(seconds: 5)), 0);
    });

    test('signal-encoded child exit is re-raised by the leader', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'm_sig';
      final leader = await Process.start(perl, [
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
        'sh',
        '-c',
        r'sleep 30 & (sleep 0.2; kill -TERM $$) & wait',
      ]);
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      final exitLine = await lines.next();
      expect(exitLine, startsWith('exit:'));
      client.writeln('settle');
      await client.flush();
      expect(await lines.next(), 'settled');
      await client.close();
      final code = await leader.exitCode.timeout(const Duration(seconds: 5));
      expect(
        code,
        lessThan(0),
        reason: 'leader should die from re-raised signal',
      );
    });

    test('control EOF kills the admitted target (host-death guard)', () async {
      final binding = await _bindControl();
      addTearDown(() => binding.dispose());
      const marker = 'conf_marker_eof';
      final workDir = Directory.systemTemp.createTempSync('p1-eof-');
      final leader = await Process.start(perl, [
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
        'sh',
        '-c',
        r'sleep 3600 & echo $! > child.pid; wait',
      ], workingDirectory: workDir.path);
      final client = await binding.server.first.timeout(
        const Duration(seconds: 5),
      );
      final lines = _LineReader(client);
      expect(await lines.next(), marker);
      expect(await lines.next(), 'started');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final childPid = int.parse(
        File('${workDir.path}/child.pid').readAsStringSync().trim(),
      );
      await client.close();
      await leader.exitCode.timeout(const Duration(seconds: 5));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      var dead = false;
      while (DateTime.now().isBefore(deadline)) {
        if ((await Process.run('kill', ['-0', '$childPid'])).exitCode != 0) {
          dead = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(dead, isTrue, reason: 'leader must kill group on host EOF');
      addTearDown(() async {
        try {
          await Process.run('kill', ['-9', '$childPid']);
        } on Object {
          // Already dead.
        }
        if (workDir.existsSync()) {
          workDir.deleteSync(recursive: true);
        }
      });
    });
  });
}

Future<String> _expectKilledGroup(_LineReader lines) async {
  final line = await lines.next();
  if (line.startsWith('exit:')) {
    return await lines.next();
  }
  return line;
}

Future<String> _readReadyLine(List<int> stderrBytes, String marker) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final text = utf8.decode(stderrBytes, allowMalformed: true);
    final line = text
        .split('\n')
        .firstWhere(
          (row) => row.startsWith('$marker:ready:'),
          orElse: () => '',
        );
    if (line.isNotEmpty) return line;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('timed out waiting for $marker:ready line');
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
    final directory = await Directory.systemTemp.createTemp('p1-conf-');
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

final class _LineReader {
  _LineReader(this._socket) {
    _subscription = _socket.listen((chunk) => _buffer.addAll(chunk));
  }

  final Socket _socket;
  final _buffer = <int>[];
  late final StreamSubscription<List<int>> _subscription;

  Future<String> next() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final index = _buffer.indexOf(10);
      if (index >= 0) {
        final line = utf8.decode(
          _buffer.sublist(0, index),
          allowMalformed: true,
        );
        _buffer.removeRange(0, index + 1);
        return line;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out waiting for control line');
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}
