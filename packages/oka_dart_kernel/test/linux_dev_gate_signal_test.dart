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
  final hang = args.contains('--hang-on-quit');
  stdout.writeln('dev: ready — commands: r [file] | R | q');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final t = line.trim();
    if (t == 'q') {
      if (hang) await Future<void>.delayed(const Duration(hours: 1));
      exit(0);
    }
  }
}
''';

String _okaRepoRoot() => findOkaRepoRoot();

void main() {
  test(
    'SIGTERM on gate owner (DevGateSignalCoordinator + interruptCleanup) '
    'terminates owned hang tree, not sentinel',
    () async {
      final scratch = await Directory.systemTemp.createTemp('oka_gate_sig');
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
        'gate_sigterm_driver.dart',
      );

      expect(File(pkgConfig).existsSync(), isTrue, reason: pkgConfig);
      expect(File(driver).existsSync(), isTrue, reason: driver);

      final owner = await Process.start(
        Platform.resolvedExecutable,
        ['--packages=$pkgConfig', driver, scratch.path, stub.path],
      );

      final tracked = <int>[];
      final ready = Completer<void>();
      final log = StringBuffer();
      void onLine(String line) {
        log.writeln(line);
        if (line.startsWith('GATE_SIG_TRACKED:')) {
          final list = jsonDecode(line.substring('GATE_SIG_TRACKED:'.length));
          tracked.addAll((list as List).cast<int>());
        }
        if (line.contains('GATE_SIG_REGRESSION_READY')) {
          if (!ready.isCompleted) ready.complete();
        }
      }

      owner.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onLine);
      owner.stderr.transform(utf8.decoder).listen(log.write);

      await ready.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          throw TimeoutException('driver output:\n$log');
        },
      );
      expect(tracked, isNotEmpty, reason: 'hang stub must own a process tree');

      final decoy = await Process.start('sleep', ['3600']);
      addTearDown(() {
        if (decoy.pid > 0) Process.killPid(decoy.pid, ProcessSignal.sigkill);
      });

      owner.kill();
      final exitCode = await owner.exitCode.timeout(const Duration(seconds: 30));
      expect(exitCode, 143);

      const liveness = HostProcessLiveness();
      for (final pid in tracked) {
        expect(
          await liveness.isAlive(pid),
          isFalse,
          reason: 'owned pid $pid must die after SIGTERM cleanup',
        );
      }
      expect(await liveness.isAlive(decoy.pid), isTrue);
    },
  skip: Platform.isWindows ? 'posix SIGTERM' : false,
  timeout: const Timeout(Duration(seconds: 90)),
  );
}
