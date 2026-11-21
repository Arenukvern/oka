import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_service/oka_service.dart';
import 'package:test/test.dart';

class _CapturingRunner implements ProcessRunner {
  _CapturingRunner({this.failOn});
  final String? failOn;
  final executed = <String>[];

  @override
  Future<ProcOutcome> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    executed.add('$executable ${arguments.join(' ')}');
    return executable == failOn
        ? const ProcOutcome(exitCode: 1, stdout: '', stderr: 'boom')
        : const ProcOutcome(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  group('CommandPipeline', () {
    test('runs commands in order and stops at the first failure', () async {
      final runner = _CapturingRunner(failOn: 'docker');
      const pipeline = CommandPipeline(
        platform: 'server',
        commands: [
          CommandSpec('jaspr', ['build']),
          CommandSpec('docker', ['build', '-t', 'app', '.']),
          CommandSpec('never', ['runs']),
        ],
      );
      final ctx = BuildContext(
        projectPath: '/p',
        buildDir: '/p/.oka_cache/build/debug',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
        processRunner: runner,
      );
      final result = await pipeline.run(ctx);
      expect(result.ok, isFalse);
      expect(result.error, contains('command "docker" failed'));
      expect(runner.executed.length, 2);
      expect(runner.executed.last, contains('docker build'));
    });

    test('provides the resolved artifact path on success', () async {
      const pipeline = CommandPipeline(
        platform: 'landing',
        commands: [
          CommandSpec('jaspr', ['build']),
        ],
        artifactId: 'landing-dir',
        artifactPath: 'build/jaspr/web',
      );
      final ctx = BuildContext(
        projectPath: '/p',
        buildDir: '',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
        processRunner: _CapturingRunner(),
      );
      final result = await pipeline.run(ctx);
      expect(result.ok, isTrue);
      expect(result.data['landing-dir'], '/p/build/jaspr/web');
    });

    test('command spec equality is field-wise', () {
      expect(
        const CommandSpec('jaspr', ['build']),
        const CommandSpec('jaspr', ['build']),
      );
      expect(
        const CommandSpec('jaspr', ['build', '--wasm']),
        isNot(const CommandSpec('jaspr', ['build'])),
      );
    });
  });

  group('GitHubReleasePublishTarget', () {
    test('dry-run chain validates without the asset present', () {
      const target = GitHubReleasePublishTarget(
        repository: 'owner/cli',
        tag: 'v1.2.3',
        assetPath: 'build/cli',
      );
      final steps = target.compile(
        BuildContext(
          projectPath: Directory.systemTemp.path,
          buildDir: '',
          mode: BuildMode.debug,
          config: OkaConfig.empty,
        ),
      );
      expect(steps.map((s) => s.name).toList(), [
        'stage-file:release-asset',
        'publish-plan',
      ]);
    });

    test('upload args are pure argv (no shell anywhere)', () {
      const target = GitHubReleasePublishTarget(
        repository: 'owner/cli',
        tag: 'v9.9.9',
      );
      final step = GhReleaseUploadStep(target);
      expect(step.uploadArgs(BuildContext.empty, '/tmp/asset'), [
        'release',
        'upload',
        'v9.9.9',
        '/tmp/asset',
        '--repo',
        'owner/cli',
        '--clobber',
      ]);
    });

    test('validates repository and tag at composition time', () {
      const target = GitHubReleasePublishTarget(
        repository: 'no-slash',
        tag: '',
      );
      expect(target.validateConfig().join('\n'), contains('owner/repo'));
      expect(target.validateConfig().join('\n'), contains('tag is empty'));
    });

    test('capability: permissive platform — a service has no platform law', () {
      const target = GitHubReleasePublishTarget(repository: 'o/r', tag: 'v1');
      const delivery = DeliveryTarget(
        name: 'svc-release',
        pipeline: CommandPipeline(
          platform: 'server',
          commands: [
            CommandSpec('docker', ['build', '.']),
          ],
        ),
        channel: target,
      );
      expect(delivery.validateComposition(), isEmpty);
    });
  });
}
