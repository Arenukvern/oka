// ADR-0016 W0 — step-chain test through Pipeline.validate + run against a
// temp dir, plus the generic WebZipStep and the honest-delegation build
// step with a fake process runner.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _RecordingRunner implements ProcessRunner {
  _RecordingRunner(this.exitCode);
  final int exitCode;
  String? lastExecutable;
  List<String> lastArgs = [];

  @override
  Future<ProcOutcome> run(
    final String executable,
    final List<String> arguments, {
    final String? workingDirectory,
    final Map<String, String>? environment,
    final Duration? timeout,
  }) async {
    lastExecutable = executable;
    lastArgs = arguments;
    return ProcOutcome(exitCode: exitCode, stdout: '', stderr: '');
  }
}

BuildContext tempContext(final Directory temp, {final ProcessRunner? runner}) =>
    BuildContext(
      projectPath: temp.path,
      buildDir: p.join(temp.path, '.oka', 'build'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      processRunner: runner,
    );

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka_web_steps_');
    Directory(p.join(temp.path, 'web', 'icons')).createSync(recursive: true);
    File(p.join(temp.path, 'web', 'icons', 'Icon-192.png'))
        .writeAsBytesSync([0x89, 0x50]);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('Pipeline.validate accepts the full chain', () {
    final pipeline = Pipeline([
      ValidateWebShellStep(
        shell: const WebShell(
          spec: WebShellSpec(
            title: 'Example',
            icons: WebIconSpec(icon192: 'icons/Icon-192.png'),
          ),
        ),
        webDir: p.join(temp.path, 'web'),
      ),
      EmitWebShellStep(
        emitter: const GenerateShellEmitter(),
        webDir: p.join(temp.path, 'web'),
      ),
      WebZipStep(outputZipPath: p.join(temp.path, 'out', 'app.zip')),
    ]);
    expect(pipeline.validate(), isNull);
  });

  test('full chain run: validate → emit → zip against a temp dir', () async {
    final pipeline = Pipeline([
      ValidateWebShellStep(
        shell: const WebShell(
          spec: WebShellSpec(
            title: 'Example',
            description: 'chain test',
            icons: WebIconSpec(icon192: 'icons/Icon-192.png'),
          ),
        ),
        webDir: p.join(temp.path, 'web'),
      ),
      EmitWebShellStep(
        emitter: const GenerateShellEmitter(),
        webDir: p.join(temp.path, 'web'),
      ),
      WebZipStep(outputZipPath: p.join(temp.path, 'out', 'app.zip')),
    ]);
    final result = await pipeline.run(tempContext(temp));
    expect(result.ok, isTrue, reason: result.error ?? '');

    // Files written with the composed shell render in the summary data.
    final indexHtml = File(p.join(temp.path, 'web', 'index.html'));
    final manifestJson = File(p.join(temp.path, 'web', 'manifest.json'));
    expect(indexHtml.existsSync(), isTrue);
    expect(manifestJson.existsSync(), isTrue);
    expect(indexHtml.readAsStringSync(), contains('<title>Example</title>'));
    expect(manifestJson.readAsStringSync(), contains('"name": "Example"'));

    // Zip artifact exists and decodes with the emitted entries.
    final zip = File(p.join(temp.path, 'out', 'app.zip'));
    expect(zip.existsSync(), isTrue);
    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    expect(
      archive.map((final f) => f.name),
      containsAll(['index.html', 'manifest.json', 'icons/Icon-192.png']),
    );
  });

  test('zip step is deterministic (sorted relative paths)', () async {
    Directory(p.join(temp.path, 'zdir', 'b')).createSync(recursive: true);
    Directory(p.join(temp.path, 'zdir', 'a')).createSync(recursive: true);
    File(p.join(temp.path, 'zdir', 'b', '2.txt')).writeAsStringSync('2');
    File(p.join(temp.path, 'zdir', 'a', '1.txt')).writeAsStringSync('1');
    File(p.join(temp.path, 'zdir', '0.txt')).writeAsStringSync('0');
    final step = WebZipStep(
      inputArtifact: const Artifact<String>('in-dir'),
      outputArtifact: const Artifact<String>('out-zip'),
      outputZipPath: p.join(temp.path, 'z.zip'),
    );
    final state = PipelineState();
    state['in-dir'] = p.join(temp.path, 'zdir');
    final result = await step.run(tempContext(temp), state);
    expect(result.ok, isTrue, reason: result.error ?? '');
    final archive = ZipDecoder()
        .decodeBytes(File(p.join(temp.path, 'z.zip')).readAsBytesSync());
    expect(archive.map((final f) => f.name).toList(),
        ['0.txt', 'a/1.txt', 'b/2.txt']);
    expect(state['out-zip'], p.join(temp.path, 'z.zip'));
  });

  test('missing directory artifact fails with an actionable error', () async {
    final step = WebZipStep(
      inputArtifact: const Artifact<String>('in-dir'),
      outputArtifact: const Artifact<String>('out-zip'),
    );
    final result = await step.run(tempContext(temp), PipelineState());
    expect(result.ok, isFalse);
    expect(result.error, contains('"in-dir" is missing or not a path'));
  });

  test('emit step surfaces the inject emitter failure as a step failure',
      () async {
    // No index.html on disk → the inject emitter fails (missing file).
    final pipeline = Pipeline([
      ValidateWebShellStep(
        shell: const WebShell(spec: WebShellSpec(title: 'Example')),
        webDir: p.join(temp.path, 'web'),
      ),
      EmitWebShellStep(
        emitter: const InjectShellEmitter(),
        webDir: p.join(temp.path, 'web'),
      ),
    ]);
    final result = await pipeline.run(tempContext(temp));
    expect(result.ok, isFalse);
    expect(result.error, contains('index.html not found'));
    expect(result.error, contains('`generate` emitter'));
  });

  group('FlutterWebBuildStep (the honest delegation)', () {
    test('runs flutter build web with base href and defines', () async {
      final runner = _RecordingRunner(0);
      final ctx = BuildContext(
        projectPath: temp.path,
        buildDir: p.join(temp.path, '.oka', 'build'),
        mode: BuildMode.release,
        config: OkaConfig.empty,
        dartDefines: const {'STORE': 'ya'},
        processRunner: runner,
      );
      final step =
          FlutterWebBuildStep(baseHref: '/games/', extraArgs: const ['--wasm']);
      final result = await step.run(ctx, PipelineState());
      expect(result.ok, isTrue, reason: result.error ?? '');
      expect(runner.lastExecutable, 'flutter');
      expect(runner.lastArgs, [
        'build',
        'web',
        '--base-href=/games/',
        '--dart-define=STORE=ya',
        '--wasm',
      ]);
      expect(
        result.data['delegation'],
        'flutter build web (not an oka-owned pipeline)',
      );
    });

    test('empty base href omits the flag; SDK path prefixes the executable',
        () async {
      final runner = _RecordingRunner(0);
      // Note: BuildContext.copyWith drops processRunner (oka_core quirk),
      // so both fields are set in the constructor here.
      final ctx = BuildContext(
        projectPath: temp.path,
        buildDir: p.join(temp.path, '.oka', 'build'),
        mode: BuildMode.debug,
        config: OkaConfig.empty,
        flutterSdkPath: '/opt/flutter',
        processRunner: runner,
      );
      final result =
          await FlutterWebBuildStep().run(ctx, PipelineState());
      expect(result.ok, isTrue);
      expect(runner.lastExecutable, '/opt/flutter/bin/flutter');
      expect(runner.lastArgs, ['build', 'web']);
    });

    test('non-zero exit fails with stdout/stderr', () async {
      final runner = _RecordingRunner(1);
      final result = await FlutterWebBuildStep()
          .run(tempContext(temp, runner: runner), PipelineState());
      expect(result.ok, isFalse);
      expect(result.error, contains('flutter build web failed'));
    });

    test('buildArgs is pure and flag-exact', () {
      final args = FlutterWebBuildStep(baseHref: '/x/')
          .buildArgs(tempContext(temp));
      expect(args, ['build', 'web', '--base-href=/x/']);
    });
  });
}
