import 'package:oka_android/oka_android.dart';

/// Attach argv for `oka dev android`: single source for spawn and diagnostics.
List<String> buildDevAndroidAttachArgv({
  required String deviceId,
  required DevLaunchPrepared prepared,
}) =>
    flutterAttachMachineArgs(
      deviceId: deviceId,
      deviceVmServicePort: prepared.vmServiceDevicePort,
      hostVmServicePort: prepared.vmServiceLocalPort,
      ddsPort: attachDdsPortWhenOkaOwnsHostForward,
    );

/// Spawns attach and releases the prepare-phase forward on spawn failure.
Future<DaemonTransport> spawnDevAndroidAttachTransport({
  required String projectPath,
  required String flutterBinary,
  required List<String> attachArgv,
  required String adbPath,
  required String deviceId,
  required DevLaunchPrepared prepared,
  AdbArgvRunner? runAdb,
  AttachDaemonProcessStarter? processStartForTest,
}) async {
  try {
    return await spawnAttachDaemon(
      flutterBinary: flutterBinary,
      flutterAttachArgv: attachArgv,
      adbPath: adbPath,
      processStartForTest: processStartForTest,
    );
  } on Object catch (e) {
    final forwardRelease = await releaseDevLaunchOwnedForward(
      adbPath: adbPath,
      deviceId: deviceId,
      hostLocalPort: prepared.vmServiceLocalPort,
      runAdb: runAdb,
    );
    await tryWriteAttachSpawnFailureDiagnostic(
      projectPath: projectPath,
      primaryError: e.toString(),
      flutterAttachArgv: attachArgv,
      forwardRelease: forwardRelease,
      hostVmServicePort: prepared.vmServiceLocalPort,
      deviceVmServicePort: prepared.vmServiceDevicePort,
      attachDdsPort: attachDdsPortWhenOkaOwnsHostForward,
    );
    rethrow;
  }
}
