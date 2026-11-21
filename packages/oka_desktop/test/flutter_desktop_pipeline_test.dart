import 'package:oka_core/oka_core.dart';
import 'package:oka_desktop/oka_desktop.dart';
import 'package:test/test.dart';

class _CapturingRunner implements ProcessRunner {
  List<String>? lastArgs;

  @override
  Future<ProcOutcome> run(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    lastArgs = args;
    return const ProcOutcome(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  group('MacosPipeline', () {
    test(
      'delegates to flutter build macos with release + variant ctx',
      () async {
        final runner = _CapturingRunner();
        const pipeline = MacosPipeline();
        final ctx = BuildContext(
          projectPath: '/p',
          buildDir: '/p/.oka_cache/build/release',
          mode: BuildMode.release,
          config: OkaConfig.empty,
          targetOverride: 'lib/entrypoints/main_store_apple_store.dart',
          dartDefines: {'STORE': 'apple-store'},
          processRunner: runner,
        );
        await check(pipeline, ctx, runner, expectedTarget: true);
      },
    );

    test('describes the delegation honestly', () {
      expect(
        const MacosPipeline().description,
        contains('delegates to flutter build macos'),
      );
      expect(const MacosPipeline().platform, 'macos');
    });
  });

  group('LinuxPipeline', () {
    test('debug mode omits --release and provides the bundle id', () async {
      final runner = _CapturingRunner();
      const pipeline = LinuxPipeline();
      final ctx = BuildContext(
        projectPath: '/p',
        buildDir: '/p/.oka_cache/build/debug',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
        processRunner: runner,
      );
      await check(pipeline, ctx, runner, expectedTarget: false);
    });
  });

  group('WindowsPipeline', () {
    test('arg vector is pure and order-stable', () {
      const pipeline = WindowsPipeline();
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.release,
        config: OkaConfig.empty,
        dartDefines: {'A': '1', 'B': '2'},
      );
      expect(pipeline.buildArgs(ctx), [
        'build',
        'windows',
        '--release',
        '--dart-define=A=1',
        '--dart-define=B=2',
      ]);
    });
  });
}

Future<void> check(
  FlutterDesktopPipeline pipeline,
  BuildContext ctx,
  _CapturingRunner runner, {
  required bool expectedTarget,
}) async {
  final result = await pipeline.run(ctx);
  expect(result.ok, isTrue);
  expect(runner.lastArgs?.first, 'build');
  expect(runner.lastArgs?[1], pipeline.buildSubcommand);
  if (expectedTarget) {
    expect(
      runner.lastArgs,
      contains('--target=lib/entrypoints/main_store_apple_store.dart'),
    );
    expect(runner.lastArgs, contains('--dart-define=STORE=apple-store'));
  } else {
    expect(runner.lastArgs, isNot(contains('--release')));
  }
  final data = result.data;
  expect(data, contains(pipeline.artifactId));
}
