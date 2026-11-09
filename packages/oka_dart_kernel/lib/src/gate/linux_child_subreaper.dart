import 'linux_child_subreaper_stub.dart'
    if (dart.library.ffi) 'linux_child_subreaper_linux.dart';

/// Sets `PR_SET_CHILD_SUBREAPER` on **this process only** (dedicated supervisor).
// ignore: avoid_classes_with_only_static_members
abstract final class LinuxChildSubreaper {
  static bool activate() => activateChildSubreaper();

  /// Linux only; `-1` elsewhere or on failure.
  static int currentProcessId() => readCurrentProcessId();
}
