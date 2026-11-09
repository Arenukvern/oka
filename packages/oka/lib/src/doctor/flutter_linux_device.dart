import 'dart:convert';

/// Parsed `flutter devices --machine` output for Linux **desktop** readiness.
final class FlutterLinuxDeviceParse {
  const FlutterLinuxDeviceParse({
    this.linuxDesktopDeviceIds = const [],
    this.error,
  });

  /// Non-emulator devices whose [targetPlatform] is exactly `linux`.
  final List<String> linuxDesktopDeviceIds;

  /// Set when stdout is not valid JSON or not a device array.
  final String? error;

  bool get hasLinuxDesktop => linuxDesktopDeviceIds.isNotEmpty;

  /// Parses Flutter's machine JSON — never treats substring `"linux"` in names
  /// (e.g. an Android device named `linux-phone`) as a desktop host.
  // ignore: prefer_constructors_over_static_methods — named factory keeps call site clear.
  static FlutterLinuxDeviceParse fromMachineStdout(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const FlutterLinuxDeviceParse(
        error: 'flutter devices --machine: empty output',
      );
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! List) {
        return const FlutterLinuxDeviceParse(
          error: 'flutter devices --machine: expected JSON array',
        );
      }
      final ids = <String>[];
      for (final entry in decoded) {
        if (entry is! Map) {
          return const FlutterLinuxDeviceParse(
            error: 'flutter devices --machine: array element is not an object',
          );
        }
        final platform = entry['targetPlatform']?.toString();
        if (platform != 'linux') continue;
        if (entry['emulator'] == true) continue;
        final id = entry['id']?.toString();
        if (id == null || id.isEmpty) {
          return const FlutterLinuxDeviceParse(
            error: 'flutter devices --machine: linux device missing id',
          );
        }
        ids.add(id);
      }
      return FlutterLinuxDeviceParse(linuxDesktopDeviceIds: ids);
    } on FormatException catch (e) {
      return FlutterLinuxDeviceParse(
        error: 'flutter devices --machine: malformed JSON ($e)',
      );
    }
  }
}
