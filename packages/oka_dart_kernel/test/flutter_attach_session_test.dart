import 'dart:async';
import 'dart:io';
import 'package:oka_dart_kernel/flutter_attach_session.dart';
import 'package:test/test.dart';

void main() {
  test(
    'attach argv, fresh acknowledgement after log rollover, coalesced detach',
    () async {
      final fixture = File(
        'test/fixtures/fake_flutter_attach.dart',
      ).absolute.path;
      List<String>? arguments;
      final session = await FlutterAttachSession.start(
        project: Directory.current.path,
        flutterBin: '/fake/flutter',
        extraArgs: ['--target=lib/alternate.dart'],
        vmUri: Uri.parse('http://127.0.0.1:9999/fake-token=/'),
        processStarter: (executable, args, {workingDirectory}) {
          expect(executable, '/fake/flutter');
          arguments = args;
          return Process.start(Platform.resolvedExecutable, [
            fixture,
          ], workingDirectory: workingDirectory);
        },
      );
      try {
        expect(arguments, [
          'attach',
          '-d',
          'macos',
          '--debug-url',
          'http://127.0.0.1:9999/fake-token=/',
          '--debug',
          '--target=lib/alternate.dart',
        ]);
        session.write('r');
        // Exercise buffered completion after the original bounded log has rolled.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          await session.waitFor(
            'Reloaded',
            timeout: const Duration(seconds: 2),
          ),
          'Reloaded 1 of 1 libraries',
        );
        expect(await Future.wait([session.detach(), session.detach()]), [0, 0]);
        expect(await session.detach(), 0);
      } finally {
        await session.detach();
      }
    },
  );

  test(
    'back-to-back commands followed by detach do not bind stdin sink',
    () async {
      final session = await FlutterAttachSession.start(
        project: Directory.current.path,
        flutterBin: '/fake/flutter',
        vmUri: Uri.parse('http://127.0.0.1:9999/fake-token=/'),
        processStarter: (_, args, {workingDirectory}) => Process.start(
          Platform.resolvedExecutable,
          [File('test/fixtures/fake_flutter_attach.dart').absolute.path],
        ),
      );
      try {
        session.write('r');
        session.write('r');
        expect(await session.detach(), 0);
      } finally {
        await session.detach();
      }
    },
  );
}
