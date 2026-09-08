/// Dev-loop readiness checks for `oka doctor` (ADR-0011 H5).
///
/// The command formats the returned lines (parse-and-delegate, ADR-0015);
/// every check mechanic lives here with the rest of the dev-loop logic:
///
/// * newest oka-built debug APK exists **and** carries a session manifest
///   (`run_session.json`, schema 1, debug mode) — the flag-parity record
///   `oka dev` refuses to run without;
/// * the flutter binary of the **recorded** SDK path exists (never PATH);
/// * adb is present and at least one device is ready — attach-capable.
library;

import 'package:path/path.dart' as p;

import '../build/toolchain.dart';
import 'adb_tool.dart';
import 'device_steps.dart' show findNewestBuiltApk;
import 'run_session.dart';

/// Result of [devLoopDoctorChecks]: overall readiness + printable lines.
///
/// [blocking] failures are environment-level (no manifest / no recorded
/// flutter binary / no adb) — the doctor summary counts them. A missing
/// device is advisory (⚠️): a phone is often intentionally unplugged, and
/// `oka dev` itself refuses with the precise fix when it matters.
class DevDoctorReport {
  const DevDoctorReport({
    required this.ok,
    required this.blocking,
    required this.lines,
  });

  /// True when `oka dev` could run right now (device included).
  final bool ok;

  /// True only for environment-level failures (doctor summary counts).
  final bool blocking;
  final List<String> lines;
}

/// Runs the dev-loop readiness checks. [checkDevice] can be disabled for
/// environments without a device expectation (CI) — the device check is
/// the only one that needs adb to exist.
Future<DevDoctorReport> devLoopDoctorChecks({
  required final String projectPath,
  final ResolvedToolchain? toolchain,
  final String? adbPath,
  final bool checkDevice = true,
}) async {
  final lines = <String>[];

  // 1. Newest built APK + session manifest (flag-parity record).
  final apk = await findNewestBuiltApk(projectPath);
  if (apk == null) {
    lines.add(
      '  ❌ dev session: no built APK under .oka_cache/build/ — run '
      '`oka build apk --debug` first',
    );
    return DevDoctorReport(ok: false, blocking: true, lines: lines);
  }
  final session = RunSession.forApk(apk);
  if (session == null) {
    lines.add(
      '  ❌ dev session: $apk has no run_session.json (pre-manifest '
      'build) — re-run `oka build apk --debug`',
    );
    return DevDoctorReport(ok: false, blocking: true, lines: lines);
  }
  if (session.buildMode != 'debug') {
    lines.add(
      '  ❌ dev session: newest APK is ${session.buildMode} — hot reload '
      'is debug-only (ADR-0011 §5); run `oka build apk --debug`',
    );
    return DevDoctorReport(ok: false, blocking: true, lines: lines);
  }
  lines.add(
    '  ✅ dev session manifest: ${p.relative(apk, from: projectPath)} '
    '(target=${session.targetFile}, mode=debug, engine '
    '${session.engineRevision.length >= 12 ? session.engineRevision.substring(0, 12) : session.engineRevision})',
  );

  // 2. Attach-capable flutter binary from the recorded SDK path.
  final binary = flutterBinaryForSdk(session.flutterSdkPath);
  if (binary.exists) {
    lines.add('  ✅ session flutter binary: ${binary.path} (recorded SDK)');
  } else {
    lines.add(
      '  ❌ session flutter binary missing: ${binary.path} — reinstall the '
      'SDK or re-run `oka build apk --debug`',
    );
    return DevDoctorReport(ok: false, blocking: true, lines: lines);
  }

  if (!checkDevice) {
    return DevDoctorReport(ok: true, blocking: false, lines: lines);
  }

  // 3. adb present + a ready device (attach-capable).
  try {
    final tool = AdbTool(
      adbPath: adbPath ?? await (toolchain ?? ResolvedToolchain()).findAdb(),
    );
    final devices = await tool.devices();
    final ready = devices.where((final d) => d.ready).toList();
    if (ready.isEmpty) {
      lines.add(
        '  ⚠️  dev session: no ready device — connect one (USB debugging) '
        'or start the emulator (`emulator -avd <name>`)',
      );
      return DevDoctorReport(ok: false, blocking: false, lines: lines);
    }
    lines.add(
      '  ✅ device: ${ready.map((final d) => d.id).join(', ')} ready for '
      'attach',
    );
  } on Exception catch (e) {
    lines.add('  ⚠️  dev session: device check unavailable — $e');
    return DevDoctorReport(ok: false, blocking: false, lines: lines);
  }

  return DevDoctorReport(ok: true, blocking: false, lines: lines);
}
