import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  group('androidAvdStateWorkflow', () {
    late Directory temp;
    late Directory project;
    late String avdHome;
    late File userdata;
    late SessionStateManager manager;

    setUp(() async {
      final scratch = await Directory.systemTemp.createTemp('oka-avd-state-');
      temp = Directory(await scratch.resolveSymbolicLinks());
      project = Directory('${temp.path}/project');
      await project.create();
      avdHome = '${temp.path}/avds';
      await Directory(avdHome).create();
      userdata = File('$avdHome/userdata-qemu.img');
      await userdata.writeAsString('existing userdata');
      manager = SessionStateManager(
        registry: SessionStateRegistry(
          Directory('${temp.path}/registry'),
          bootId: 'test-boot',
        ),
      );
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test(
      'records persistent inventory and reuses the same AVD lease',
      () async {
        final request = SessionStateRequest(
          projectPath: project.path,
          sessionName: 'default',
          metadata: {'avd_name': 'oka-ci', 'avd_home': avdHome},
        );

        final first = await manager.acquire(androidAvdStateWorkflow, request);
        final second = await manager.acquire(androidAvdStateWorkflow, request);

        expect(first.id, second.id);
        expect(first.namespace, SessionStateNamespace.host);
        expect(first.retention, SessionStateRetention.persistent);
        expect(first.ownership, SessionStateOwnership.caller);
        expect(first.acquisitionMode, SessionStateAcquisitionMode.borrowed);
        expect(first.resourceKind, SessionStateResourceKind.opaque);
        expect(first.phase, SessionStatePhase.ready);
        expect(first.metadata['avd_name'], 'oka-ci');
        expect((await manager.registry.inspect()).leases, hasLength(1));
        final restored = await const AndroidAvdSource().restore(second);
        expect(restored.name, 'oka-ci');
        expect(restored.avdHome, avdHome);
        expect(await userdata.readAsString(), 'existing userdata');
        expect(androidAvdStateWorkflow.provision, isEmpty);
        expect(androidAvdStateWorkflow.cleanup, isEmpty);
      },
    );

    test(
      'visible matching emulator is busy, absent adb evidence is unknown',
      () async {
        final lease = await manager.acquire(
          androidAvdStateWorkflow,
          SessionStateRequest(
            projectPath: project.path,
            sessionName: 'default',
            metadata: {'avd_name': 'oka-ci', 'avd_home': avdHome},
          ),
        );
        final context = SessionStateContext<AndroidAvdHandle>(
          handle: AndroidAvdHandle(name: 'oka-ci', avdHome: avdHome),
          lease: lease,
        );

        final busy = await AndroidAvdUseInspector(
          listDevices: () async => const [
            AdbDevice(id: 'emulator-5554', state: 'device'),
          ],
          readAvdName: (final _) async => 'oka-ci',
        ).inspect(context);
        final unknown = await AndroidAvdUseInspector(
          listDevices: () async => const [],
        ).inspect(context);

        expect(busy.use, SessionStateUse.busy);
        expect(busy.details['serial'], 'emulator-5554');
        expect(unknown.use, SessionStateUse.unknown);
        expect(unknown.reason, contains('cannot prove host-global'));
      },
    );

    test('an adb inspection failure remains unknown', () async {
      final finding =
          await AndroidAvdUseInspector(
            listDevices: () async => throw StateError('adb unavailable'),
          ).inspect(
            SessionStateContext<AndroidAvdHandle>(
              handle: AndroidAvdHandle(name: 'oka-ci', avdHome: avdHome),
              lease: await manager.acquire(
                androidAvdStateWorkflow,
                SessionStateRequest(
                  projectPath: project.path,
                  sessionName: 'default',
                  metadata: {'avd_name': 'oka-ci', 'avd_home': avdHome},
                ),
              ),
            ),
          );

      expect(finding.use, SessionStateUse.unknown);
      expect(finding.reason, contains('adb unavailable'));
    });
  });
}
