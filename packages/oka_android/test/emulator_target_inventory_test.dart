import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  test('EmulatorTarget contributes its Android AVD inventory workflow', () {
    final workflows = const Oka(
      pipelines: [],
      targets: [EmulatorTarget()],
    ).effectiveSessionStateWorkflows;

    expect(workflows, hasLength(1));
    expect(workflows.single, same(androidAvdStateWorkflow));
  });

  group('EmulatorTarget AVD inventory recording', () {
    late Directory temp;
    late Directory project;
    late Directory avdHome;
    late SessionStateRegistry registry;

    setUp(() async {
      final scratch = await Directory.systemTemp.createTemp(
        'oka-emulator-target-',
      );
      temp = Directory(await scratch.resolveSymbolicLinks());
      project = Directory('${temp.path}/project');
      await project.create();
      avdHome = Directory('${temp.path}/avds');
      await avdHome.create();
      await File(
        '${avdHome.path}/oka-test.ini',
      ).writeAsString('path=${temp.path}/avds/oka-test.avd\n');
      registry = SessionStateRegistry(
        Directory('${temp.path}/registry'),
        bootId: 'test-boot',
      );
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    BuildContext buildContext() => BuildContext(
      projectPath: project.path,
      buildDir: '${project.path}/build',
      mode: BuildMode.debug,
      config: OkaConfig.empty,
    );

    test(
      'target records selected AVD metadata and reuses its inventory lease',
      () async {
        final target = EmulatorTarget(
          avdName: 'oka-test',
          avdHome: avdHome.path,
          sessionStateRegistry: registry,
        );
        final recordStep = target
            .compile(
              BuildContext(
                projectPath: project.path,
                buildDir: '${project.path}/build',
                mode: BuildMode.debug,
                config: OkaConfig.empty,
              ),
            )
            .last;
        expect(recordStep, isA<RecordAndroidAvdInventoryStep>());
        expect(recordStep.requires, contains(emulatorSerial));

        final state = PipelineState()..[emulatorSerial.id] = 'emulator-5554';
        final firstResult = await recordStep.run(buildContext(), state);
        final firstSnapshot = await registry.inspect();
        final first = firstSnapshot.leases.single;

        final secondResult = await recordStep.run(buildContext(), state);
        final second = (await registry.inspect()).leases.single;

        expect(firstResult.ok, isTrue);
        expect(secondResult.ok, isTrue);
        expect(first.id, second.id);
        expect(first.workflowId, androidAvdStateWorkflow.id);
        expect(first.phase, SessionStatePhase.ready);
        expect(first.namespace, SessionStateNamespace.host);
        expect(first.retention, SessionStateRetention.persistent);
        expect(first.ownership, SessionStateOwnership.caller);
        expect(first.acquisitionMode, SessionStateAcquisitionMode.borrowed);
        expect(first.resourceKind, SessionStateResourceKind.opaque);
        expect(first.rootPath, avdHome.path);
        expect(first.relativePath, 'oka-test');
        expect(first.metadata['avd_name'], 'oka-test');
        expect(first.metadata['avd_home'], avdHome.path);
      },
    );

    test(
      'resolves Android AVD, user-home, SDK-home, and default locations',
      () async {
        final avdHomeResolution = await resolveAndroidAvdHome(
          avdName: 'oka-test',
          environment: {'ANDROID_AVD_HOME': avdHome.path},
        );
        expect(avdHomeResolution.path, avdHome.path);

        final userHome = Directory('${temp.path}/user-home');
        final userAvdHome = Directory('${userHome.path}/avd');
        await userAvdHome.create(recursive: true);
        await File('${userAvdHome.path}/oka-test.ini').create();
        final userHomeResolution = await resolveAndroidAvdHome(
          avdName: 'oka-test',
          environment: {'ANDROID_USER_HOME': userHome.path},
        );
        expect(userHomeResolution.path, userAvdHome.path);

        final sdkHome = Directory('${temp.path}/sdk-home');
        final sdkAvdHome = Directory('${sdkHome.path}/.android/avd');
        await sdkAvdHome.create(recursive: true);
        await File('${sdkAvdHome.path}/oka-test.ini').create();
        final sdkHomeResolution = await resolveAndroidAvdHome(
          avdName: 'oka-test',
          environment: {'ANDROID_SDK_HOME': sdkHome.path},
        );
        expect(sdkHomeResolution.path, sdkAvdHome.path);

        final defaultAvdHome = Directory('${temp.path}/.android/avd');
        await defaultAvdHome.create(recursive: true);
        await File('${defaultAvdHome.path}/oka-test.ini').create();
        final defaultResolution = await resolveAndroidAvdHome(
          avdName: 'oka-test',
          environment: {'HOME': temp.path},
        );
        expect(defaultResolution.path, defaultAvdHome.path);
      },
    );

    test('unresolvable home is a non-fatal observation limitation', () async {
      final step = RecordAndroidAvdInventoryStep(
        avdName: 'oka-test',
        avdHome: '${temp.path}/missing-avd-home',
        registry: registry,
      );
      final result = await step.run(
        buildContext(),
        PipelineState()..[emulatorSerial.id] = 'emulator-5554',
      );

      expect(result.ok, isTrue);
      expect(result.data['avd_inventory'], 'unavailable');
      expect(result.data['limitation'], contains('no inventory lease'));
      expect((await registry.inspect()).leases, isEmpty);
    });
  });
}
