import 'dart:io';

import 'package:oka_android/src/dependencies/androidx_provisioner.dart';
import 'package:oka_android/src/plugins/native_build_service.dart';
import 'package:oka_android/src/tools/resolved_toolchain.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_androidx_tools_');
  });

  tearDown(() => temp.delete(recursive: true));

  test('legacy AndroidX cache remains the first read-only source', () async {
    final legacy = File(
      p.join(
        temp.path,
        '.oka',
        'cache',
        'androidx',
        'annotation-jvm-1.9.1.jar',
      ),
    );
    await legacy.parent.create(recursive: true);
    await legacy.writeAsString('legacy');
    var processCalls = 0;
    final provisioner = AndroidxJarProvisioner(
      store: LocalArtifactStore(root: p.join(temp.path, 'store')),
      environment: {'HOME': temp.path},
      processRunner:
          (
            executable,
            arguments, {
            environment,
            stdoutEncoding,
            stderrEncoding,
          }) async {
            processCalls++;
            return ProcessResult(1, 0, '', '');
          },
    );

    expect(await provisioner.findAndroidXAnnotations(), legacy.path);
    expect(processCalls, 0);
  });

  test(
    'store miss uses injected download and temporary-directory seams',
    () async {
      final storeRoot = p.join(temp.path, 'store');
      final scratch = Directory(p.join(temp.path, 'scratch'));
      var downloads = 0;
      var tempRequests = 0;
      final provisioner = AndroidxJarProvisioner(
        store: LocalArtifactStore(root: storeRoot),
        environment: {'HOME': p.join(temp.path, 'home')},
        tempDirectoryFactory: (prefix) async {
          tempRequests++;
          return scratch..createSync(recursive: true);
        },
        processRunner:
            (
              executable,
              arguments, {
              environment,
              stdoutEncoding,
              stderrEncoding,
            }) async {
              expect(executable, 'curl');
              downloads++;
              final output = arguments[arguments.indexOf('-o') + 1];
              await File(output).writeAsBytes(List<int>.filled(1200, 1));
              return ProcessResult(1, 0, <int>[], <int>[]);
            },
      );

      final first = await provisioner.findAndroidXAnnotations();
      expect(File(first).existsSync(), isTrue);
      expect(downloads, 1);
      expect(tempRequests, 1);
      expect(scratch.existsSync(), isFalse);
    },
  );

  test('NDK lookup honors its injected environment', () async {
    final sdkNdk = Directory(p.join(temp.path, 'sdk', 'ndk', '27.0'));
    final configured = await Directory(
      p.join(temp.path, 'configured-ndk'),
    ).create(recursive: true);
    await sdkNdk.create(recursive: true);

    expect(
      await findNdkHome(
        p.join(temp.path, 'sdk'),
        environment: {'ANDROID_NDK_HOME': configured.path},
      ),
      configured.path,
    );
    expect(
      await findNdkHome(p.join(temp.path, 'sdk'), environment: const {}),
      sdkNdk.path,
    );
  });

  test('Java resolution delegates through the injected resolver', () async {
    String? requestedVersion;
    final toolchain = ResolvedToolchain(
      javaEnvironmentResolver: (version) async {
        requestedVersion = version;
        return const {'JAVA_HOME': '/fixture/java'};
      },
    );
    final context = BuildContext(
      projectPath: temp.path,
      buildDir: p.join(temp.path, 'build'),
      mode: BuildMode.debug,
      config: const OkaConfig({
        'android': {'required_java_version': '21'},
      }),
    );

    expect(await toolchain.resolveJavaForKotlin(context), {
      'JAVA_HOME': '/fixture/java',
    });
    expect(requestedVersion, '21');
  });
}
