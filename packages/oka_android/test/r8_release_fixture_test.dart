import 'dart:io';

import 'package:oka_android/src/build/r8_tool.dart';
import 'package:oka_android/src/compilation/bytecode_compilation.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// End-to-end shrinking fixture (ADR-0023 release-readiness evidence): the
/// real pipeline function (`compileAndroidBytecode`) drives **real** javac,
/// `jar`, and the **real R8 jar** (Google Maven, oka-managed) over a tiny
/// program — proving the exact argument set oka emits produces DEX +
/// mapping, and that R8 actually tree-shakes unused classes.
///
/// Skips when `java`/`javac` are absent or R8 cannot be provisioned, so the
/// suite stays green on machines without toolchains (CI provisions both).
void main() {
  test(
    'real R8 release compile: dex + mapping + tree-shaken unused class',
    () async {
      final java = await _which('javac') ?? await _which('javac.exe');
      if (java == null) {
        return markTestSkipped('javac not available — R8 fixture skipped');
      }
      final r8 = await findR8Jar() ?? await _installR8ForFixture();
      if (r8 == null) {
        return markTestSkipped('R8 unavailable — R8 fixture skipped');
      }

      final temp = await Directory.systemTemp.createTemp('oka_r8_fixture_');
      addTearDown(() => temp.delete(recursive: true));
      final buildDir = p.join(temp.path, '.oka_cache');

      // Program sources: the entry point references `Used`; `Unused` is
      // unreachable — a real release build must remove it.
      final host = Directory(p.join(temp.path, 'host'))..createSync();
      File(p.join(host.path, 'Host.java')).writeAsStringSync('''
public class Host extends android.app.Activity {
  public int value() { return new com.example.Used().compute(); }
}
''');
      final gen = Directory(p.join(temp.path, 'gen'))..createSync();
      // Stub android.jar + embedding (compiled by the fixture itself so the
      // javac classpath exists without a real SDK).
      final stubSrc = Directory(p.join(temp.path, 'stub'))..createSync();
      // java.lang.Object must exist in the stub bootclasspath — without it
      // R8 tree-shakes the whole program away and exits 0 with no dex
      // (a real android.jar always carries java.*). Extract the runtime's
      // own Object.class from the JDK modules image.
      final javaHome = await _javaHome();
      if (javaHome == null) {
        return markTestSkipped('java.home not discoverable — fixture skipped');
      }
      final jimageDir = p.join(temp.path, 'java-base');
      final extract = await Process.run(p.join(javaHome, 'bin', 'jimage'), [
        'extract',
        '--include',
        r'regex:/java\.base/.*\.class',
        '--dir',
        jimageDir,
        p.join(javaHome, 'lib', 'modules'),
      ]);
      expect(
        extract.exitCode,
        0,
        reason: 'jimage extract failed: ${extract.stderr}',
      );
      _write(p.join(stubSrc.path, 'android/app/Activity.java'), '''
package android.app;
import android.os.Bundle;
public class Activity { protected void onCreate(Bundle b) {} }
''');
      _write(
        p.join(stubSrc.path, 'android/os/Bundle.java'),
        'package android.os; public class Bundle {}',
      );
      _write(p.join(stubSrc.path, 'com/example/Used.java'), '''
package com.example;
public class Used { public int compute() { return 42; } }
''');
      _write(p.join(stubSrc.path, 'com/example/Unused.java'), '''
package com.example;
public class Unused { public int gone() { return 1; } }
''');
      final stubClasses = p.join(temp.path, 'stub-classes');
      final stubJavac = await Process.run('javac', [
        '--release',
        '11',
        '-d',
        stubClasses,
        ..._javaFiles(stubSrc),
      ]);
      expect(
        stubJavac.exitCode,
        0,
        reason: 'stub compilation failed: ${stubJavac.stderr}',
      );
      final androidJar = p.join(temp.path, 'android.jar');
      // Bootclasspath stub = android.* + the runtime's java.base (flattened
      // — R8 rejects `java.base/`-prefixed entry names). A real android.jar
      // carries the same java.* stubs.
      final bootDir = p.join(temp.path, 'boot');
      Directory(p.join(bootDir, 'android')).createSync(recursive: true);
      _copyDir(
        Directory(p.join(stubClasses, 'android')),
        Directory(p.join(bootDir, 'android')),
      );
      _copyDir(Directory(p.join(jimageDir, 'java.base')), Directory(bootDir));
      await Process.run('jar', ['cf', androidJar, '-C', bootDir, '.']);
      final embeddingJar = p.join(temp.path, 'embedding.jar');
      await _jar(embeddingJar, stubClasses, 'com');

      final ctx = BuildContext(
        projectPath: temp.path,
        buildDir: buildDir,
        mode: BuildMode.release,
        config: const OkaConfig({
          'android': {
            'java_version': 17,
            'min_sdk': '24',
            'abis': ['arm64-v8a'],
          },
        }),
      );

      final outcome = await compileAndroidBytecode(
        ctx: ctx,
        tools: BytecodeTools(javac: 'javac', d8: 'd8', r8: r8),
        hostDir: host.path,
        generatedSourcesDir: gen.path,
        androidJar: androidJar,
        embeddingJar: embeddingJar,
        dependencyJars: const [],
        // Real process execution — no fake runners in this fixture.
        processRunner: (executable, arguments, {environment}) async {
          final result = await Process.run(
            executable,
            arguments,
            environment: environment,
            runInShell: Platform.isWindows,
          );
          final isR8 =
              executable == 'java' &&
              arguments.contains('com.android.tools.r8.R8');
          if (result.exitCode != 0 || isR8) {
            stderr.writeln(
              'fixture: $executable ${arguments.join(' ')}\n'
              'fixture: exit ${result.exitCode}\n'
              'fixture: stdout: ${result.stdout}\n'
              'fixture: stderr: ${result.stderr}',
            );
          }
          return result;
        },
      );

      expect(outcome.ok, isTrue, reason: outcome.error ?? 'no error');
      expect(outcome.dexFiles, isNotEmpty);
      final mapping = File(p.join(buildDir, 'r8', 'mapping.txt'));
      expect(mapping.existsSync(), isTrue, reason: 'mapping.txt must exist');
      final mappingText = mapping.readAsStringSync();
      // `Used` is reachable from the entry point → kept and mapped.
      expect(mappingText, contains('com.example.Used'));
      // `Unused` is unreachable → tree-shaken (absent from the mapping).
      expect(mappingText, isNot(contains('com.example.Unused')));
      // The collective configuration must be reproducible.
      final configuration = File(p.join(buildDir, 'r8', 'configuration.txt'));
      expect(configuration.existsSync(), isTrue, reason: 'R8 conf output');
      expect(outcome.shrinkerArtifacts['mapping'], endsWith('mapping.txt'));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

void _copyDir(final Directory from, final Directory to) {
  for (final e in from.listSync(recursive: true)) {
    final relative = p.relative(e.path, from: from.path);
    final target = p.join(to.path, relative);
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      File(target).parent.createSync(recursive: true);
      e.copySync(target);
    }
  }
}

void _write(final String path, final String content) {
  File(path).parent.createSync(recursive: true);
  File(path).writeAsStringSync(content);
}

List<String> _javaFiles(final Directory root) => [
  for (final e in root.listSync(recursive: true))
    if (e is File && e.path.endsWith('.java')) e.path,
];

Future<void> _jar(
  final String jarPath,
  final String baseDir,
  final String relativeDir,
) async {
  await Process.run('jar', ['cf', jarPath, '-C', baseDir, relativeDir]);
}

Future<String?> _which(final String command) async {
  final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
    command,
  ], runInShell: Platform.isWindows);
  if (result.exitCode != 0) return null;
  final first = (result.stdout as String).trim().split('\n').first.trim();
  return first.isEmpty ? null : first;
}

/// `java.home` from the running JVM (used to locate the modules image).
Future<String?> _javaHome() async {
  final result = await Process.run('java', [
    '-XshowSettings:properties',
    '-version',
  ]);
  for (final line in (result.stderr as String).split('\n')) {
    final match = RegExp(r'java\.home\s*=\s*(.+)').firstMatch(line);
    if (match != null) return match.group(1)!.trim();
  }
  return null;
}

/// Provision R8 for the fixture only when explicitly allowed, so ordinary
/// test runs never download (CI sets this when R8 should be exercised).
Future<String?> _installR8ForFixture() async {
  if (Platform.environment['OKA_R8_FIXTURE_ALLOW_DOWNLOAD'] != '1') {
    return null;
  }
  try {
    final jar = await installR8();
    return File(jar).existsSync() ? jar : null;
  } on Exception {
    return null;
  }
}
