// ADR-0015 C1 — `oka debug dex` moves behind the Android package.
//
// Covers:
// * the probe implementation (`checkDexSymbols` in oka_android) against
//   synthetic APK zips (pure Dart — no unzip binary, no SDK);
// * the CLI delegation: `oka debug dex` only parses args, then exits with
//   the probe's exit-code semantics (0 present / 1 absent / 2 no dex).
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Writes a minimal zip acting as an APK with the given dex entries.
Future<String> fakeApk(
  final Directory dir,
  final Map<String, String> dexEntries,
) async {
  final archive = Archive();
  for (final entry in dexEntries.entries) {
    archive.addFile(
      ArchiveFile.bytes(
        entry.key,
        entry.value.codeUnits,
      ),
    );
  }
  final apk = File(p.join(dir.path, 'app-debug.apk'));
  await apk.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return apk.path;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_dex_probe_');
    addTearDown(() => tmp.delete(recursive: true));
  });

  group('checkDexSymbols (oka_android)', () {
    test('present descriptor (dotted query) is found in classes.dex',
        () async {
      final apk = await fakeApk(tmp, {
        'classes.dex': 'blah Lcom/example/Foo; blah',
        'classes2.dex': 'unrelated pool',
      });
      final lines = <String>[];
      final outcome = await checkDexSymbols(
        apk: apk,
        queries: ['com.example.Foo'],
        emit: lines.add,
      );
      expect(outcome.ok, isTrue);
      expect(outcome.exitCode, 0);
      expect(lines.join('\n'), contains('✅ Lcom/example/Foo;'));
      expect(lines.join('\n'), contains('classes.dex'));
    });

    test('absent descriptor fails with the NoClassDefFoundError hint',
        () async {
      final apk = await fakeApk(tmp, {
        'classes.dex': 'Lother/Thing;',
      });
      final lines = <String>[];
      final outcome = await checkDexSymbols(
        apk: apk,
        queries: ['com.example.Missing'],
        emit: lines.add,
      );
      expect(outcome.allPresent, isFalse);
      expect(outcome.exitCode, 1);
      expect(lines.join('\n'), allOf(
        contains('ABSENT'),
        contains('NoClassDefFoundError'),
      ));
    });

    test('descriptor-form queries pass through unchanged', () async {
      final apk = await fakeApk(tmp, {
        'classes.dex': 'Lkotlinx/atomicfu/AtomicFU;',
      });
      final outcome = await checkDexSymbols(
        apk: apk,
        queries: ['Lkotlinx/atomicfu/AtomicFU;'],
        emit: (_) {},
      );
      expect(outcome.ok, isTrue);
    });

    test('no dex entries → dexEntriesFound false, exit code 2', () async {
      final apk = await fakeApk(tmp, {
        'res/values.xml': 'not a dex',
      });
      final lines = <String>[];
      final outcome = await checkDexSymbols(
        apk: apk,
        queries: ['com.example.Foo'],
        emit: lines.add,
      );
      expect(outcome.dexEntriesFound, isFalse);
      expect(outcome.exitCode, 2);
      expect(lines.join('\n'), contains('no classes*.dex'));
    });

    test('non-zip file is reported, never throws', () async {
      final apk = File(p.join(tmp.path, 'junk.apk'));
      await apk.writeAsBytes(List.filled(32, 0));
      final outcome = await checkDexSymbols(
        apk: apk.path,
        queries: ['com.example.Foo'],
        emit: (_) {},
      );
      expect(outcome.dexEntriesFound, isFalse);
      expect(outcome.exitCode, 2);
    });
  });

  group('oka debug dex CLI delegation', () {
    Future<ProcessResult> cli(final List<String> args) => Process.run(
          'dart',
          ['run', 'packages/oka/bin/oka.dart', 'debug', 'dex', ...args],
          workingDirectory: Directory.current.path,
        );

    test('exit 0 when the class is present', () async {
      final apk = await fakeApk(tmp, {
        'classes.dex': 'Lcom/example/Foo;',
      });
      final result = await cli([apk, '--find', 'com.example.Foo']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('🔍 DEX symbol check'));
    });

    test('exit 1 when the class is absent', () async {
      final apk = await fakeApk(tmp, {
        'classes.dex': 'Lcom/example/Foo;',
      });
      final result = await cli([apk, '--find', 'com.example.Missing']);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('ABSENT'));
    });

    test('missing APK file exits 2', () async {
      final result = await cli([
        p.join(tmp.path, 'nope.apk'),
        '--find',
        'com.example.Foo',
      ]);
      expect(result.exitCode, 2);
      expect(result.stdout, contains('not found'));
    });
  });
}
