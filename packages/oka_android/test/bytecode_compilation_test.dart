import 'dart:io';

import 'package:oka_android/src/compilation/bytecode_compilation.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('BytecodeCommandPolicy', () {
    test(
      'shuffled inputs produce identical sorted classpaths and D8 inputs',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'oka_bytecode_policy_',
        );
        addTearDown(() => temp.delete(recursive: true));
        final jars = <String>[];
        for (final name in ['z-runtime.jar', 'a-runtime.jar']) {
          final file = File(p.join(temp.path, name));
          await file.writeAsBytes(List<int>.filled(201, 1));
          jars.add(file.path);
        }
        const policy = BytecodeCommandPolicy(pathSeparator: ':');
        final firstClasspath = policy.compileClasspath(
          androidJar: 'android.jar',
          embeddingJar: 'embedding.jar',
          dependencyJars: jars,
        );
        final secondClasspath = policy.compileClasspath(
          androidJar: 'android.jar',
          embeddingJar: 'embedding.jar',
          dependencyJars: jars.reversed.toList(),
        );
        expect(firstClasspath, secondClasspath);
        final firstPrograms = policy.programJars(
          classesJar: 'classes.jar',
          embeddingJar: 'embedding.jar',
          runtimeJars: jars,
        );
        final secondPrograms = policy.programJars(
          classesJar: 'classes.jar',
          embeddingJar: 'embedding.jar',
          runtimeJars: jars.reversed.toList(),
        );
        expect(firstPrograms, secondPrograms);
        expect(firstPrograms, orderedEquals([...firstPrograms]..sort()));
      },
    );

    test(
      'argument construction accepts immutable inputs without host files',
      () {
        const policy = BytecodeCommandPolicy(pathSeparator: ':');
        const java = ['Z.java', 'A.java'];
        const kotlin = ['Z.kt', 'A.kt'];
        expect(
          policy.kotlinArgs(
            classpath: const ['api.jar'],
            classesDir: 'classes',
            javaVersion: 17,
            kotlinSources: kotlin,
            javaSources: java,
          ),
          containsAllInOrder(['A.kt', 'Z.kt', 'A.java', 'Z.java']),
        );
        expect(
          policy.javacArgs(
            classpath: const ['api.jar'],
            classesDir: 'classes',
            javaVersion: 17,
            javaSources: java,
          ),
          containsAllInOrder(['A.java', 'Z.java']),
        );
        expect(
          policy.programJars(
            classesJar: 'classes.jar',
            embeddingJar: 'embedding.jar',
            runtimeJars: const ['does-not-exist.jar'],
          ),
          contains('does-not-exist.jar'),
        );
        expect(java, ['Z.java', 'A.java']);
        expect(kotlin, ['Z.kt', 'A.kt']);
        final annotations = ['z/annotations.jar', 'a/annotations.jar'];
        expect(
          filterCompileOnlyJars(annotations),
          filterCompileOnlyJars(annotations.reversed.toList()),
        );
      },
    );

    test('platform variant wins over the KMP root on a version tie', () async {
      final temp = await Directory.systemTemp.createTemp('oka_variant_policy_');
      addTearDown(() => temp.delete(recursive: true));
      final root = File(
        p.join(
          temp.path,
          'maven',
          'org',
          'jetbrains',
          'atomicfu',
          '1.0',
          'atomicfu.jar',
        ),
      );
      final jvm = File(
        p.join(
          temp.path,
          'maven',
          'org',
          'jetbrains',
          'atomicfu-jvm',
          '1.0',
          'atomicfu-jvm.jar',
        ),
      );
      await root.parent.create(recursive: true);
      await jvm.parent.create(recursive: true);
      await root.writeAsBytes(List<int>.filled(201, 1));
      await jvm.writeAsBytes(List<int>.filled(201, 2));

      expect(filterRuntimeJars([root.path, jvm.path]), [jvm.path]);
      expect(filterRuntimeJars([jvm.path, root.path]), [jvm.path]);
    });
    test(
      'R8 arguments keep program closure, use documented CLI flags only',
      () {
        const policy = BytecodeCommandPolicy(pathSeparator: ':');
        final args = policy.r8Args(
          outputDir: 'dex',
          minApi: '23',
          androidJar: 'android.jar',
          programJars: const ['a.jar', 'b.jar'],
          libraryJars: const ['annotations.jar'],
          configFile: 'r8/config.pro',
          mappingFile: 'r8/mapping.txt',
          confOutputFile: 'r8/configuration.txt',
        );
        // Verified against `java -cp r8.jar com.android.tools.r8.R8 --help`
        // (R8 9.4.24): --seeds/--usage/--printconfiguration do not exist.
        expect(args.first, '--release');
        expect(
          args,
          containsAllInOrder(['--output', 'dex', '--min-api', '23']),
        );
        expect(args, containsAllInOrder(['--lib', 'android.jar']));
        expect(args, containsAllInOrder(['--pg-conf', 'r8/config.pro']));
        expect(args, containsAllInOrder(['--pg-map-output', 'r8/mapping.txt']));
        expect(
          args,
          containsAllInOrder(['--pg-conf-output', 'r8/configuration.txt']),
        );
        expect(args, containsAllInOrder(['a.jar', 'b.jar']));
        // Only flags that exist in the R8 CLI — a regression here is a broken
        // release build on every machine.
        expect(args.where((final a) => a.startsWith('--')).toSet(), const {
          '--release',
          '--output',
          '--min-api',
          '--lib',
          '--pg-conf',
          '--pg-map-output',
          '--pg-conf-output',
        });
      },
    );
  });

  group('compileAndroidBytecode', () {
    late Directory temp;
    late Directory host;
    late Directory generated;
    late File annotationJar;
    late BuildContext context;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('oka_bytecode_execution_');
      host = await Directory(p.join(temp.path, 'host')).create();
      generated = await Directory(p.join(temp.path, 'gen')).create();
      await File(p.join(host.path, 'Host.java')).writeAsString('class Host {}');
      annotationJar = File(p.join(temp.path, 'annotations.jar'));
      await annotationJar.writeAsBytes(List<int>.filled(201, 1));
      await Directory(p.join(temp.path, 'dex')).create();
      await File(
        p.join(temp.path, 'dex', 'classes2.dex'),
      ).writeAsString('stale');
      context = BuildContext(
        projectPath: temp.path,
        buildDir: temp.path,
        mode: BuildMode.debug,
        config: const OkaConfig({
          'android': {'java_version': 17, 'min_sdk': '23'},
        }),
      );
    });

    tearDown(() => temp.delete(recursive: true));

    test(
      'executes mutual Kotlin/Java compile, retries D8, and clears stale dex',
      () async {
        final kotlin = p.join(temp.path, 'Plugin.kt');
        await File(kotlin).writeAsString('class Plugin');
        final calls = <({String executable, List<String> arguments})>[];
        var d8Calls = 0;
        Future<ProcessResult> runner(
          String executable,
          List<String> arguments, {
          Map<String, String>? environment,
        }) async {
          calls.add((executable: executable, arguments: [...arguments]));
          if (executable == 'd8') {
            d8Calls++;
            final output = arguments[arguments.indexOf('--output') + 1];
            if (d8Calls == 1) {
              await File(
                p.join(output, 'classes2.dex'),
              ).writeAsString('partial');
              return ProcessResult(1, 1, '', 'old d8');
            }
            await File(p.join(output, 'classes.dex')).writeAsString('dex');
          }
          return ProcessResult(1, 0, '', '');
        }

        final outcome = await compileAndroidBytecode(
          ctx: context,
          tools: const BytecodeTools(
            javac: 'javac',
            d8: 'd8',
            kotlinc: 'kotlinc',
          ),
          hostDir: host.path,
          generatedSourcesDir: generated.path,
          androidJar: 'android.jar',
          embeddingJar: 'embedding.jar',
          dependencyJars: [annotationJar.path],
          pluginKotlinSources: [kotlin],
          processRunner: runner,
          environmentLoader: ({verbose = false}) async => const {},
        );

        expect(outcome.ok, isTrue);
        expect(d8Calls, 2);
        expect(
          File(p.join(temp.path, 'dex', 'classes2.dex')).existsSync(),
          isFalse,
        );
        final kotlinCall = calls.singleWhere(
          (call) => call.executable == 'kotlinc',
        );
        expect(kotlinCall.arguments, contains(p.join(host.path, 'Host.java')));
        final javacCall = calls.singleWhere(
          (call) => call.executable == 'javac',
        );
        expect(
          javacCall.arguments[javacCall.arguments.indexOf('-classpath') + 1],
          contains(p.join(temp.path, 'classes')),
        );
        final firstD8 = calls
            .where((call) => call.executable == 'd8')
            .first
            .arguments;
        final secondD8 = calls
            .where((call) => call.executable == 'd8')
            .last
            .arguments;
        expect(firstD8, contains(annotationJar.path));
        expect(secondD8, isNot(contains(annotationJar.path)));
        expect(firstD8, containsAllInOrder(['--min-api', '23']));
      },
    );

    test('reports successful D8 that produces no outputs', () async {
      final outcome = await compileAndroidBytecode(
        ctx: context,
        tools: const BytecodeTools(javac: 'javac', d8: 'd8'),
        hostDir: host.path,
        generatedSourcesDir: generated.path,
        androidJar: 'android.jar',
        embeddingJar: 'embedding.jar',
        dependencyJars: const [],
        processRunner: (executable, arguments, {environment}) async =>
            ProcessResult(1, 0, '', ''),
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('d8 produced no classes*.dex'));
    });

    test(
      'release fails when R8 is unavailable instead of falling back to D8',
      () async {
        final release = BuildContext(
          projectPath: temp.path,
          buildDir: temp.path,
          mode: BuildMode.release,
          config: const OkaConfig({
            'android': {'java_version': 17, 'min_sdk': '23'},
          }),
        );
        final executables = <String>[];
        final outcome = await compileAndroidBytecode(
          ctx: release,
          tools: const BytecodeTools(javac: 'javac', d8: 'd8'),
          hostDir: host.path,
          generatedSourcesDir: generated.path,
          androidJar: 'android.jar',
          embeddingJar: 'embedding.jar',
          dependencyJars: const [],
          // Tests must not touch the network: self-heal injected as "no".
          ensureR8Tool: ({verbose = false}) async => null,
          processRunner: (executable, arguments, {environment}) async {
            executables.add(executable);
            return ProcessResult(1, 0, '', '');
          },
        );
        expect(outcome.ok, isFalse);
        expect(outcome.error, contains('R8 is required'));
        expect(executables, isNot(contains('d8')));
      },
    );
  });
}
