import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _stubSource = r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final hang = args.contains('--hang-on-quit');
  stdout.writeln('dev: ready — commands: r [file] | R | q');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final t = line.trim();
    if (t == 'q') {
      if (hang) {
        await Future<void>.delayed(const Duration(hours: 1));
      }
      exit(0);
    }
    if (t == 'R') {
      stdout.writeln('Restarted application in 1ms.');
      stdout.writeln('restart: OK (platform lane, 1ms)');
    }
    if (t.startsWith('r')) {
      stdout.writeln('reload 1: OK');
    }
  }
}
''';

late Directory _scratch;
late String _stub;

void main() {
  setUpAll(() async {
    _scratch = await Directory.systemTemp.createTemp('oka_owned_dev_session');
    _stub = p.join(_scratch.path, 'stub.dart');
    await File(_stub).writeAsString(_stubSource);
  });

  tearDownAll(() async {
    await _scratch.delete(recursive: true);
  });

  test('teardown: q exits cleanly with no survivors', () async {
    final session = await OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: [_stub],
    );
    expect(
      await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 10)),
      isTrue,
      reason: session.transcript,
    );
    final td = await session.teardown(quitGrace: const Duration(seconds: 5));
    expect(td.clean, isTrue, reason: td.notes.join('; '));
    expect(td.survivors, isEmpty);
  });

  test('teardown: hang-on-quit is tree-stopped', () async {
    final session = await OwnedDevSession.start(
      workspace: _scratch.path,
      dartInvocation: [_stub, '--hang-on-quit'],
    );
    expect(
      await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 10)),
      isTrue,
      reason: session.transcript,
    );
    final td = await session.teardown(
      quitGrace: const Duration(milliseconds: 200),
      stopGrace: const Duration(seconds: 3),
    );
    expect(td.survivors, isEmpty, reason: 'owned tree must not survive teardown');
  });
}
