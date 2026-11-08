import 'dart:io';

/// Result of [linuxDesktopDoctorChecks] for `oka run dev --platform linux`.
class LinuxDesktopDoctorReport {
  const LinuxDesktopDoctorReport({
    required this.applicable,
    required this.ok,
    required this.blocking,
    required this.lines,
    required this.capabilities,
  });

  /// Host is Linux (checks are meaningful, not N/A).
  final bool applicable;

  /// True when the host can run the Linux desktop dev session end-to-end.
  final bool ok;

  /// Count toward doctor summary failure (environment-level only).
  final bool blocking;

  final List<String> lines;

  /// Machine-readable capability flags for tests and JSON export later.
  final Map<String, bool> capabilities;
}

typedef ShellRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

Future<ProcessResult> _defaultRunner(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) =>
    Process.run(executable, arguments, environment: environment);

/// Linux Flutter **desktop dev** readiness (JIT session — not Android dev-loop).
///
/// Parse-and-delegate for `oka doctor` (ADR-0015). Does not probe Snap Store or
/// release builds (L1+).
Future<LinuxDesktopDoctorReport> linuxDesktopDoctorChecks({
  ShellRunner run = _defaultRunner,
  bool? hostIsLinux,
}) async {
  final onLinux = hostIsLinux ?? Platform.isLinux;
  final lines = <String>[];
  final capabilities = <String, bool>{
    'host_linux': false,
    'flutter_cli': false,
    'linux_device': false,
    'gtk_dev': false,
    'display_session': false,
  };

  if (!onLinux) {
    lines.add(
      '  ℹ️  Host is not Linux — `oka run dev --platform linux` needs a Linux '
      'build host with Flutter linux desktop enabled.',
    );
    lines.add(
      '  ℹ️  Capability (this host): macOS/web/android dev paths unchanged; '
      'Linux desktop dev is validated on Ubuntu amd64 CI (L0).',
    );
    return LinuxDesktopDoctorReport(
      applicable: false,
      ok: false,
      blocking: false,
      lines: lines,
      capabilities: capabilities,
    );
  }
  capabilities['host_linux'] = true;

  var blocking = false;
  var ok = true;

  final uname = await run('uname', ['-m']);
  final arch = uname.exitCode == 0
      ? (uname.stdout as String).trim()
      : 'unknown';
  lines.add('  ℹ️  Native arch: $arch (Flutter linux desktop builds match host; '
      'arm64 hosts need arm64 CI — not implied by ubuntu-amd64 gates)');

  ProcessResult flutterVersion;
  try {
    flutterVersion = await run('flutter', ['--version']);
  } on ProcessException catch (e) {
    lines.add('  ❌ flutter: not on PATH ($e)');
    blocking = true;
    ok = false;
    return _report(lines, capabilities, blocking: blocking, ok: ok);
  }
  if (flutterVersion.exitCode != 0) {
    lines.add('  ❌ flutter --version failed');
    blocking = true;
    ok = false;
  } else {
    capabilities['flutter_cli'] = true;
    final first = (flutterVersion.stdout as String).split('\n').first.trim();
    lines.add('  ✅ flutter: $first');
  }

  final devices = await run('flutter', ['devices', '--machine']);
  if (devices.exitCode != 0) {
    lines.add('  ❌ flutter devices failed — enable linux desktop '
        '(`flutter config --enable-linux-desktop`)');
    blocking = true;
    ok = false;
  } else {
    final hasLinux = (devices.stdout as String).contains('"targetPlatform":"linux"') ||
        (devices.stdout as String).contains('linux');
    capabilities['linux_device'] = hasLinux;
    if (hasLinux) {
      lines.add('  ✅ linux desktop device listed (flutter devices)');
    } else {
      lines.add(
        '  ❌ no linux device — install GTK toolchain and run '
        '`flutter config --enable-linux-desktop`',
      );
      blocking = true;
      ok = false;
    }
  }

  final gtk = await run('pkg-config', ['--exists', 'gtk+-3.0']);
  if (gtk.exitCode == 0) {
    capabilities['gtk_dev'] = true;
    final ver = await run('pkg-config', ['--modversion', 'gtk+-3.0']);
    final v = ver.exitCode == 0 ? (ver.stdout as String).trim() : '?';
    lines.add('  ✅ GTK+3 dev (pkg-config gtk+-3.0): $v');
  } else {
    lines.add(
      '  ❌ GTK+3 dev libraries missing — on Debian/Ubuntu: '
      '`build-essential libstdc++-14-dev libgtk-3-dev pkg-config clang cmake ninja-build`',
    );
    blocking = true;
    ok = false;
  }

  final env = Platform.environment;
  final hasDisplay = (env['DISPLAY']?.isNotEmpty ?? false) ||
      (env['WAYLAND_DISPLAY']?.isNotEmpty ?? false);
  capabilities['display_session'] = hasDisplay;
  if (hasDisplay) {
    final kind = env['WAYLAND_DISPLAY']?.isNotEmpty == true
        ? 'WAYLAND_DISPLAY=${env['WAYLAND_DISPLAY']}'
        : 'DISPLAY=${env['DISPLAY']}';
    lines.add('  ✅ Desktop session: $kind');
  } else {
    lines.add(
      '  ⚠️  No DISPLAY/WAYLAND_DISPLAY — headless hosts need xvfb-run for '
      'E2E (`gate_dev_assets_linux.sh`)',
    );
    // Advisory only: CI uses xvfb; local SSH without X is common.
  }

  lines.add(
    '  ℹ️  Dev command: `oka run dev --project <dir> --platform linux` '
    '(JIT hot reload/restart; proven on L0 gates when GTK+display available)',
  );
  lines.add(
    '  ℹ️  Not in scope (L0): release `oka build linux`, Snap pack/upload — '
    'see docs/superpowers/plans/2026-11-08-linux-dev-convergence.md',
  );

  return _report(
    lines,
    capabilities,
    blocking: blocking,
    ok: ok && !blocking,
  );
}

LinuxDesktopDoctorReport _report(
  List<String> lines,
  Map<String, bool> capabilities, {
  required bool blocking,
  required bool ok,
}) =>
    LinuxDesktopDoctorReport(
      applicable: true,
      ok: ok,
      blocking: blocking,
      lines: lines,
      capabilities: capabilities,
    );
