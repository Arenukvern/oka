import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _RecordingPipeline extends PlatformPipeline {
  _RecordingPipeline(this.platform);

  @override
  final String platform;
  bool ran = false;

  @override
  Future<StepResult> run(BuildContext ctx) async {
    ran = true;
    return StepResult.success();
  }
}

class _EmptyTarget extends Target {
  const _EmptyTarget();

  @override
  String get name => 'fixture';

  @override
  String get description => 'Registration fixture';

  @override
  List<BuildStep> compile(BuildContext ctx) => [];
}

void main() {
  late Directory sandbox;
  late Directory project;
  late CacheProjectRegistry registry;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('oka-registration-');
    project = await Directory(p.join(sandbox.path, 'project')).create();
    registry = CacheProjectRegistry(environment: {'HOME': sandbox.path});
  });

  tearDown(() async {
    await sandbox.delete(recursive: true);
  });

  for (final platform in ['android', 'ios', 'web', 'linux']) {
    test('$platform execution registers the project before running', () async {
      final pipeline = _RecordingPipeline(platform);
      await okaRun(
        ['--platform', platform],
        oka: Oka(pipelines: [pipeline]),
        projectPath: project.path,
        registerCacheProject: (path) async {
          expect(pipeline.ran, isFalse);
          await registry.register(path);
        },
      );
      expect(pipeline.ran, isTrue);
      expect(await registry.projects(), [await project.resolveSymbolicLinks()]);
    });
  }

  test('target execution also registers the project', () async {
    await okaRun(
      ['--oka-run-target', 'fixture'],
      oka: const Oka(pipelines: [], targets: [_EmptyTarget()]),
      projectPath: project.path,
      registerCacheProject: registry.register,
    );
    expect(await registry.projects(), [await project.resolveSymbolicLinks()]);
  });

  for (final mode in [
    '--print-config',
    '--oka-list-targets',
    '--oka-describe-targets',
  ]) {
    test('$mode does not register or create caches', () async {
      final pipeline = _RecordingPipeline('android');
      var registered = false;
      await okaRun(
        [mode],
        oka: Oka(pipelines: [pipeline]),
        projectPath: project.path,
        registerCacheProject: (_) async => registered = true,
      );
      expect(registered, isFalse);
      expect(pipeline.ran, isFalse);
      expect(
        await Directory(p.join(project.path, '.oka_cache')).exists(),
        isFalse,
      );
      expect(await File(registry.path).exists(), isFalse);
    });
  }

  test(
    'registry failure remains advisory and does not stop execution',
    () async {
      final pipeline = _RecordingPipeline('android');
      await okaRun(
        [],
        oka: Oka(pipelines: [pipeline]),
        projectPath: project.path,
        registerCacheProject: (_) async =>
            throw const FileSystemException('fixture'),
      );
      expect(pipeline.ran, isTrue);
    },
  );

  test(
    'best-effort helper reports failure through diagnostic callback',
    () async {
      final warnings = <String>[];
      await registerCacheProjectBestEffort(
        project.path,
        register: (_) async => throw const FormatException('bad registry'),
        warning: warnings.add,
      );
      expect(warnings.single, contains('could not register project'));
    },
  );
}
