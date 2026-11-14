import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../test/support/repo_root.dart';

const _stubSource = '''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  ProcessSignal.sigterm.watch().listen((_) => exit(143));
  stdout.writeln('dev: ready');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
  if (line.trim() == 'q') exit(0);
  }
}
''';

String _okaRepoRoot() => findOkaRepoRoot();

void main() {
  test(
    'SIGTERM during session startup aborts spawned root, preserves sentinel',
    () async {
      final scratch = await Directory.systemTemp.createTemp('oka_gate_startup_sig');
      addTearDown(() => scratch.delete(recursive: true));
      final stub = File(p.join(scratch.path, 'stub.dart'));
      await stub.writeAsString(_stubSource);

      final repoRoot = _okaRepoRoot();
      final pkgConfig = p.join(repoRoot, '.dart_tool', 'package_config.json');
      final driver = p.join(
        repoRoot,
        'packages',
        'oka_dart_kernel',
        'test',
        'gate_startup_sigterm_driver.dart',
      );

      final owner = await Process.start(
        Platform.resolvedExecutable,
        ['--packages=$pkgConfig', driver, scratch.path, stub.path],
      );

      final ready = Completer<void>();
      owner.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.contains('GATE_STARTUP_DRIVER_READY')) ready.complete();
      });

      await ready.future.timeout(const Duration(seconds: 10));

      final decoy = await Process.start('sleep', ['3600']);
      addTearDown(() => Process.killPid(decoy.pid, ProcessSignal.sigkill));

      owner.kill();
      final exitCode = await owner.exitCode.timeout(const Duration(seconds: 30));
      expect(exitCode, 143);

      const liveness = HostProcessLiveness();
      expect(await liveness.isAlive(decoy.pid), isTrue);
    },
  skip: Platform.isLinux ? false : 'posix SIGTERM',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
