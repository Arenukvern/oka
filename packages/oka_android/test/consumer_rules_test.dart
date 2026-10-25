import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:oka_android/src/build/consumer_rules.dart';
import 'package:oka_android/src/build/plugin_consumer_rules.dart';
import 'package:oka_android/src/compilation/bytecode_compilation.dart';
import 'package:oka_android/src/dependencies/maven_archive.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Consumer ProGuard rules (ADR-0051) — the mechanism the Android Gradle
/// Plugin uses to let a dependency declare "these classes are optional for
/// me". oka's no-Gradle pipeline dropped the AAR `proguard.txt` entry, so
/// release builds failed in R8 on classes every declared dependency already
/// declared optional (e.g. `play-services-basement` declares
/// `-dontwarn javax.annotation.**`).
void main() {
  group('AAR consumer rules', () {
    test('reads proguard.txt from the AAR the classes jar came from', () {
      final temp = Directory.systemTemp.createTempSync('oka_consumer_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final versionDir = Directory(
        p.join(
          temp.path,
          'maven',
          'com',
          'google',
          'android',
          'gms',
          'play-services-basement',
          '18.4.0',
        ),
      )..createSync(recursive: true);
      final classesJar = p.join(
        versionDir.path,
        'play-services-basement-18.4.0-classes.jar',
      );
      File(classesJar).writeAsBytesSync(_jarBytes());
      File(
        p.join(versionDir.path, 'play-services-basement-18.4.0.aar'),
      ).writeAsBytesSync(
        _aarBytes({
          'proguard.txt': '-dontwarn javax.annotation.**\n-keep class x.Y { *; }\n',
        }),
      );

      final rules = readConsumerProguardRules(classesJar);
      expect(rules, contains('-dontwarn javax.annotation.**'));
      expect(rules, contains('-keep class x.Y'));
      expect(aarPathForClassesJar(classesJar), endsWith('.aar'));
    });

    test('a plain Maven jar declares no consumer rules', () {
      final temp = Directory.systemTemp.createTempSync('oka_consumer_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final jar = File(p.join(temp.path, 'tika-core-3.3.0.jar'));
      jar.writeAsBytesSync(_jarBytes());
      expect(readConsumerProguardRules(jar.path), isNull);
      expect(aarPathForClassesJar(jar.path), isNull);
    });

    test('falls back to the extracted payload copy when the AAR is gone', () {
      final temp = Directory.systemTemp.createTempSync('oka_consumer_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final versionDir = Directory(
        p.join(temp.path, 'maven', 'org', 'example', 'lib', '1.0.0'),
      )..createSync(recursive: true);
      final classesJar = p.join(versionDir.path, 'lib-1.0.0-classes.jar');
      File(classesJar).writeAsBytesSync(_jarBytes());
      final payload = Directory(p.join(versionDir.path, 'payload'))
        ..createSync(recursive: true);
      File(p.join(payload.path, 'proguard.txt')).writeAsStringSync(
        '-dontwarn com.example.optional.**\n',
      );

      expect(
        readConsumerProguardRules(classesJar),
        contains('-dontwarn com.example.optional.**'),
      );
    });

    test('a project-local AAR keeps its rules next to the classes jar', () {
      // `local_aars` extracts classes.jar + payload into the build dir; the
      // AAR itself stays in the project, so the sibling lookup cannot find
      // it — the extracted copy is the source.
      final temp = Directory.systemTemp.createTempSync('oka_consumer_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final workDir = Directory(
        p.join(temp.path, 'build', 'local_aars', 'analytics'),
      )..createSync(recursive: true);
      final classesJar = p.join(workDir.path, 'classes.jar');
      File(classesJar).writeAsBytesSync(_jarBytes());
      File(p.join(workDir.path, 'proguard.txt')).writeAsStringSync(
        '-keep class com.vendor.Analytics { *; }\n',
      );

      expect(
        readConsumerProguardRules(classesJar),
        contains('-keep class com.vendor.Analytics'),
      );
    });

    test('collects one rule set per artifact and names the owner', () {
      final temp = Directory.systemTemp.createTempSync('oka_consumer_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final jar = _aarBackedJar(
        temp,
        group: ['com', 'google', 'android', 'gms'],
        artifact: 'play-services-basement',
        version: '18.4.0',
        rules: '-dontwarn javax.annotation.**\n',
      );
      final plain = File(p.join(temp.path, 'plain.jar'));
      plain.writeAsBytesSync(_jarBytes());

      final collected = collectConsumerProguardRules([jar, plain.path]);
      expect(collected, hasLength(1));
      expect(
        collected.single.coordinate,
        'com.google.android.gms:play-services-basement:18.4.0',
      );
      final rendered = renderConsumerProguardRules(collected);
      expect(rendered, contains('# --- com.google.android.gms:play-services-basement:18.4.0 ---'));
      expect(rendered, contains('-dontwarn javax.annotation.**'));
    });

    test('AAR payload extraction keeps the consumer rules file', () async {
      final temp = await Directory.systemTemp.createTemp('oka_consumer_');
      addTearDown(() => temp.delete(recursive: true));
      final payload = await extractAarPayload(
        _aarBytes({'proguard.txt': '-dontwarn com.example.**\n'}),
        p.join(temp.path, 'payload'),
      );
      expect(payload.consumerProguardFile, isNotNull);
      expect(
        File(payload.consumerProguardFile!).readAsStringSync(),
        contains('-dontwarn com.example.**'),
      );
    });
  });

  group('release rule composition', () {
    test(
      'consumer rules sit between oka defaults and the app rules',
      () async {
        final temp = await Directory.systemTemp.createTemp('oka_consumer_r8_');
        addTearDown(() => temp.delete(recursive: true));
        final host = await Directory(p.join(temp.path, 'host')).create();
        final generated = await Directory(p.join(temp.path, 'gen')).create();
        final dependency = _aarBackedJar(
          temp,
          group: ['com', 'google', 'android', 'gms'],
          artifact: 'play-services-basement',
          version: '18.4.0',
          rules: '-dontwarn javax.annotation.**\n',
        );
        final context = BuildContext(
          projectPath: temp.path,
          buildDir: p.join(temp.path, 'build'),
          mode: BuildMode.release,
          config: const OkaConfig({
            'android': {'java_version': 17, 'min_sdk': '23'},
          }),
        );

        final calls = <({String executable, List<String> arguments})>[];
        final outcome = await compileAndroidBytecode(
          ctx: context,
          tools: const BytecodeTools(javac: 'javac', d8: 'd8', r8: 'r8'),
          hostDir: host.path,
          generatedSourcesDir: generated.path,
          androidJar: 'android.jar',
          embeddingJar: 'embedding.jar',
          dependencyJars: [dependency],
          processRunner: (executable, arguments, {environment}) async {
            calls.add((executable: executable, arguments: [...arguments]));
            if (executable == 'r8') {
              final reports = p.join(context.buildDir, 'r8');
              await Directory(reports).create(recursive: true);
              await File(p.join(reports, 'mapping.txt')).writeAsString('# map');
              await File(
                p.join(reports, 'configuration.txt'),
              ).writeAsString('# conf');
              final output = arguments[arguments.indexOf('--output') + 1];
              await Directory(output).create(recursive: true);
              await File(p.join(output, 'classes.dex')).writeAsString('dex');
            }
            return ProcessResult(1, 0, '', '');
          },
        );

        expect(outcome.ok, isTrue, reason: outcome.error ?? 'no error');
        final r8Args = calls
            .singleWhere((call) => call.executable == 'r8')
            .arguments;
        final confFiles = <String>[
          for (var i = 0; i < r8Args.length; i++)
            if (r8Args[i] == '--pg-conf') r8Args[i + 1],
        ];
        expect(confFiles, hasLength(2));
        expect(confFiles.first, endsWith('oka-default-rules.pro'));
        expect(confFiles.last, endsWith('oka-consumer-rules.pro'));
        final consumerRules = File(confFiles.last).readAsStringSync();
        expect(consumerRules, contains('-dontwarn javax.annotation.**'));
        expect(
          consumerRules,
          contains('com.google.android.gms:play-services-basement:18.4.0'),
        );
      },
    );
    test(
      "a source plugin's declared consumer rules reach the R8 invocation",
      () async {
        final temp = await Directory.systemTemp.createTemp('oka_consumer_r8_');
        addTearDown(() => temp.delete(recursive: true));
        final host = await Directory(p.join(temp.path, 'host')).create();
        final generated = await Directory(p.join(temp.path, 'gen')).create();
        final pluginRules = File(p.join(temp.path, 'proguard-rules.pro'))
          ..writeAsStringSync(
            '-keepattributes *JavascriptInterface*\n'
            '-keepclassmembers class * {\n'
            '    @android.webkit.JavascriptInterface <methods>;\n'
            '}\n',
          );
        final context = BuildContext(
          projectPath: temp.path,
          buildDir: p.join(temp.path, 'build'),
          mode: BuildMode.release,
          config: const OkaConfig({
            'android': {'java_version': 17, 'min_sdk': '23'},
          }),
        );

        final calls = <({String executable, List<String> arguments})>[];
        final outcome = await compileAndroidBytecode(
          ctx: context,
          tools: const BytecodeTools(javac: 'javac', d8: 'd8', r8: 'r8'),
          hostDir: host.path,
          generatedSourcesDir: generated.path,
          androidJar: 'android.jar',
          embeddingJar: 'embedding.jar',
          dependencyJars: const [],
          consumerRuleFiles: [
            PluginConsumerRuleFile(
              pluginName: 'flutter_inappwebview_android',
              path: pluginRules.path,
            ),
          ],
          processRunner: (executable, arguments, {environment}) async {
            calls.add((executable: executable, arguments: [...arguments]));
            if (executable == 'r8') {
              final reports = p.join(context.buildDir, 'r8');
              await Directory(reports).create(recursive: true);
              await File(p.join(reports, 'mapping.txt')).writeAsString('# map');
              await File(
                p.join(reports, 'configuration.txt'),
              ).writeAsString('# conf');
              final output = arguments[arguments.indexOf('--output') + 1];
              await Directory(output).create(recursive: true);
              await File(p.join(output, 'classes.dex')).writeAsString('dex');
            }
            return ProcessResult(1, 0, '', '');
          },
        );

        expect(outcome.ok, isTrue, reason: outcome.error ?? 'no error');
        final r8Args = calls
            .singleWhere((call) => call.executable == 'r8')
            .arguments;
        final confFiles = <String>[
          for (var i = 0; i < r8Args.length; i++)
            if (r8Args[i] == '--pg-conf') r8Args[i + 1],
        ];
        expect(confFiles, hasLength(2));
        expect(confFiles.last, endsWith('oka-consumer-rules.pro'));
        final rendered = File(confFiles.last).readAsStringSync();
        expect(rendered, contains('# --- flutter_inappwebview_android ---'));
        expect(rendered, contains('JavascriptInterface'));
      },
    );
  });
}

/// A store-shaped classes jar with a sibling AAR that declares [rules].
String _aarBackedJar(
  Directory root, {
  required List<String> group,
  required String artifact,
  required String version,
  required String rules,
}) {
  final versionDir = Directory(
    p.joinAll([root.path, 'maven', ...group, artifact, version]),
  )..createSync(recursive: true);
  final classesJar = p.join(versionDir.path, '$artifact-$version-classes.jar');
  File(classesJar).writeAsBytesSync(_jarBytes());
  File(p.join(versionDir.path, '$artifact-$version.aar')).writeAsBytesSync(
    _aarBytes({'proguard.txt': rules}),
  );
  return classesJar;
}

/// A jar with enough bytes to survive the runtime-jar size filter.
///
/// The bytes are pseudo-random on purpose: an all-zero payload deflates to
/// far below the filter's 200-byte floor, which would drop the artifact
/// from the runtime classpath before the consumer rules are read.
List<int> _jarBytes() {
  final random = Random(7);
  final archive = Archive()
    ..addFile(
      ArchiveFile(
        'com/example/Marker.class',
        400,
        List<int>.generate(400, (_) => random.nextInt(256)),
      ),
    );
  return ZipEncoder().encodeBytes(archive);
}

/// An AAR archive with the given extra entries.
List<int> _aarBytes(Map<String, String> entries) {
  final archive = Archive()
    ..addFile(
      ArchiveFile('classes.jar', _jarBytes().length, _jarBytes()),
    );
  entries.forEach((name, content) {
    archive.addFile(ArchiveFile(name, content.length, content.codeUnits));
  });
  return ZipEncoder().encodeBytes(archive);
}
