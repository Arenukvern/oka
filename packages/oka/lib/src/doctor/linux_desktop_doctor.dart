import 'dart:io';

import 'flutter_linux_device.dart';
import 'tool_probe.dart';

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

/// Linux Flutter **desktop dev** readiness (JIT session — not Android dev-loop).
///
/// Parse-and-delegate for `oka doctor` (ADR-0015). Does not probe Snap Store or
/// release builds (L1+).
Future<LinuxDesktopDoctorReport> linuxDesktopDoctorChecks({
  ToolProbeRunner probe = defaultToolProbe,
  bool? hostIsLinux,
}) async {
  final onLinux = hostIsLinux ?? Platform.isLinux;
  final lines = <String>[];
  final capabilities = <String, bool>{
    'host_linux': false,
    'native_arch': false,
    'flutter_cli': false,
    'linux_device': false,
    'gtk_dev': false,
    'clang': false,
    'cmake': false,
    'ninja': false,
    'cpp_link': false,
    'display_session': false,
    'display_runnable_now': false,
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

  final uname = await probe('uname', ['-m'], deadline: const Duration(seconds: 5));
  if (!uname.ran && uname.missing) {
    lines.add('  ❌ uname: not found on PATH');
    blocking = true;
    ok = false;
  } else if (uname.timedOut) {
    lines.add('  ❌ uname: timed out (${uname.errorMessage})');
    blocking = true;
    ok = false;
  } else if (!uname.ok) {
    lines.add('  ❌ uname -m failed (exit ${uname.exitCode})');
    blocking = true;
    ok = false;
  } else {
    capabilities['native_arch'] = true;
    final arch = uname.stdout.trim();
    lines.add(
      '  ℹ️  Native arch: ${arch.isEmpty ? 'unknown' : arch} (Flutter linux '
      'desktop builds match host; arm64 hosts need arm64 CI — not implied by '
      'ubuntu-amd64 gates)',
    );
  }

  final flutterVersion = await probe(
    'flutter',
    ['--version'],
    deadline: const Duration(seconds: 30),
  );
  if (flutterVersion.missing) {
    lines.add('  ❌ flutter: not on PATH');
    blocking = true;
    ok = false;
  } else if (flutterVersion.timedOut) {
    lines.add('  ❌ flutter --version: timed out');
    blocking = true;
    ok = false;
  } else if (flutterVersion.spawnFailed) {
    lines.add('  ❌ flutter: failed to start (${flutterVersion.errorMessage})');
    blocking = true;
    ok = false;
  } else if (!flutterVersion.ok) {
    lines.add('  ❌ flutter --version failed (exit ${flutterVersion.exitCode})');
    blocking = true;
    ok = false;
  } else {
    capabilities['flutter_cli'] = true;
    final first = flutterVersion.stdout.split('\n').first.trim();
    lines.add('  ✅ flutter installed: $first');
  }

  final devices = await probe(
    'flutter',
    ['devices', '--machine'],
    deadline: const Duration(seconds: 60),
  );
  if (!devices.ok) {
    final detail = devices.missing
        ? 'flutter not on PATH'
        : devices.timedOut
        ? 'timed out'
        : 'exit ${devices.exitCode}';
    lines.add(
      '  ❌ flutter devices --machine failed ($detail) — enable linux desktop '
      '(`flutter config --enable-linux-desktop`)',
    );
    blocking = true;
    ok = false;
  } else {
    final parsed = FlutterLinuxDeviceParse.fromMachineStdout(devices.stdout);
    if (parsed.error != null) {
      lines.add('  ❌ ${parsed.error}');
      blocking = true;
      ok = false;
    } else if (parsed.hasLinuxDesktop) {
      capabilities['linux_device'] = true;
      lines.add(
        '  ✅ linux desktop device (${parsed.linuxDesktopDeviceIds.join(', ')})',
      );
    } else {
      lines.add(
        '  ❌ no linux desktop device in machine list — install GTK toolchain '
        'and run `flutter config --enable-linux-desktop`',
      );
      blocking = true;
      ok = false;
    }
  }

  for (final tool in [
    ('clang', '--version', 'clang'),
    ('cmake', '--version', 'cmake'),
    ('ninja', '--version', 'ninja'),
  ]) {
    final r = await probe(
      tool.$1,
      [tool.$2],
      deadline: const Duration(seconds: 10),
    );
    capabilities[tool.$3] = r.ok;
    if (r.missing) {
      lines.add('  ❌ ${tool.$1}: not on PATH (install build-essential toolchain)');
      blocking = true;
      ok = false;
    } else if (r.timedOut) {
      lines.add('  ❌ ${tool.$1}: probe timed out');
      blocking = true;
      ok = false;
    } else if (!r.ok) {
      lines.add('  ❌ ${tool.$1}: probe failed (exit ${r.exitCode})');
      blocking = true;
      ok = false;
    } else {
      final headline = r.stdout.split('\n').first.trim();
      lines.add('  ✅ ${tool.$1}: ${headline.isEmpty ? 'ok' : headline}');
    }
  }

  final gtk = await probe(
    'pkg-config',
    ['--exists', 'gtk+-3.0'],
    deadline: const Duration(seconds: 10),
  );
  if (gtk.missing) {
    lines.add('  ❌ pkg-config: not on PATH');
    blocking = true;
    ok = false;
  } else if (gtk.timedOut) {
    lines.add('  ❌ pkg-config gtk+-3.0: timed out');
    blocking = true;
    ok = false;
  } else if (gtk.ok) {
    capabilities['gtk_dev'] = true;
    final ver = await probe(
      'pkg-config',
      ['--modversion', 'gtk+-3.0'],
      deadline: const Duration(seconds: 5),
    );
    final v = ver.ok ? ver.stdout.trim() : '?';
    lines.add('  ✅ GTK+3 dev (pkg-config gtk+-3.0): $v');
  } else {
    lines.add(
      '  ❌ GTK+3 dev libraries missing — on Debian/Ubuntu: '
      '`build-essential libstdc++-14-dev libgtk-3-dev pkg-config clang cmake ninja-build`',
    );
    blocking = true;
    ok = false;
  }

  // Minimal C++ link probe — separate "installed" toolchain from link-ready now.
  if (capabilities['clang'] == true) {
    final link = await probe(
      'sh',
      [
        '-c',
        r"printf '%s\n' 'int main(){return 0;}' | clang++ -x c++ - -o /dev/null -lstdc++",
      ],
      deadline: const Duration(seconds: 20),
    );
    if (link.ok) {
      capabilities['cpp_link'] = true;
      lines.add('  ✅ C++ link probe (clang++ + libstdc++)');
    } else {
      final why = link.missing
          ? 'clang++ missing'
          : link.timedOut
          ? 'timed out'
          : 'exit ${link.exitCode}';
      lines.add(
        '  ❌ C++ link probe failed ($why) — install libstdc++-14-dev (or distro equivalent)',
      );
      blocking = true;
      ok = false;
    }
  }

  final env = Platform.environment;
  final hasDisplay = (env['DISPLAY']?.isNotEmpty ?? false) ||
      (env['WAYLAND_DISPLAY']?.isNotEmpty ?? false);
  capabilities['display_session'] = hasDisplay;
  capabilities['display_runnable_now'] = hasDisplay;
  if (hasDisplay) {
    final kind = env['WAYLAND_DISPLAY']?.isNotEmpty == true
        ? 'WAYLAND_DISPLAY=${env['WAYLAND_DISPLAY']}'
        : 'DISPLAY=${env['DISPLAY']}';
    lines.add('  ✅ Display session (runnable now): $kind');
  } else {
    lines.add(
      '  ⚠️  No DISPLAY/WAYLAND_DISPLAY — GUI not runnable now; headless E2E '
      'needs xvfb-run (doctor still OK for compile-only)',
    );
  }

  lines.add(
    '  ℹ️  Dev command: `oka run dev --project <dir> --platform linux` '
    '(JIT hot reload/restart; proven on L0 gates when GTK+display available)',
  );
  lines.add(
    '  ℹ️  Not in scope (L0): release `oka build linux`, Snap pack/upload — '
    'see docs/superpowers/plans/2026-11-08-linux-dev-convergence.md',
  );

  return LinuxDesktopDoctorReport(
    applicable: true,
    ok: ok && !blocking,
    blocking: blocking,
    lines: lines,
    capabilities: capabilities,
  );
}
