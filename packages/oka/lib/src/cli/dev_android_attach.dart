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
