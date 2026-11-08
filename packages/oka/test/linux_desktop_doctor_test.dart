import 'package:oka/src/doctor/linux_desktop_doctor.dart';
import 'package:oka/src/doctor/tool_probe.dart';
import 'package:test/test.dart';

ToolProbeRunner _fake(Map<String, ToolProbeResult> table) =>
    (
      executable,
      arguments, {
      deadline = const Duration(seconds: 15),
    }) async {
      final key = '$executable ${arguments.join(' ')}';
      return table[key] ??
          ToolProbeResult(
            ran: false,
            missing: true,
            errorMessage: 'not found: $key',
          );
    };

void main() {
  test('hostIsLinux false: advisory only, not blocking', () async {
    final report = await linuxDesktopDoctorChecks(hostIsLinux: false);
    expect(report.applicable, isFalse);
    expect(report.blocking, isFalse);
    expect(report.lines.join('\n'), contains('not Linux'));
  });

  test('Linux fixtures: full OK when flutter+gtk+display present', () async {
    final report = await linuxDesktopDoctorChecks(
      hostIsLinux: true,
      probe: _fake({
        'uname -m': const ToolProbeResult(ran: true, exitCode: 0, stdout: 'x86_64\n'),
        'flutter --version': const ToolProbeResult(
          ran: true,
          exitCode: 0,
          stdout: 'Flutter 3.35.0 • channel stable\n',
        ),
        'flutter devices --machine': const ToolProbeResult(
          ran: true,
          exitCode: 0,
          stdout: '[{"id":"linux","targetPlatform":"linux","emulator":false}]',
        ),
        'clang --version': const ToolProbeResult(
          ran: true,
          exitCode: 0,
          stdout: 'clang version 18\n',
        ),
        'cmake --version': const ToolProbeResult(
          ran: true,
          exitCode: 0,
          stdout: 'cmake version 3.28\n',
        ),
        'ninja --version': const ToolProbeResult(
          ran: true,
          exitCode: 0,
          stdout: '1.11.1\n',
        ),
        'pkg-config --exists gtk+-3.0': const ToolProbeResult(
          ran: true,
          exitCode: 0,
        ),
        'pkg-config --modversion gtk+-3.0': const ToolProbeResult(
          ran: true,
          exitCode: 0,
          stdout: '3.24.41\n',
        ),
        'sh -c printf \'%s\\n\' \'int main(){return 0;}\' | clang++ -x c++ - -o /dev/null -lstdc++':
            const ToolProbeResult(ran: true, exitCode: 0),
      }),
    );
    expect(report.applicable, isTrue);
    expect(report.ok, isTrue);
    expect(report.blocking, isFalse);
    expect(report.capabilities['linux_device'], isTrue);
    expect(report.capabilities['gtk_dev'], isTrue);
    expect(report.capabilities['cpp_link'], isTrue);
  });

  test('Linux fixtures: android linux-phone does not satisfy linux_device', () async {
    final report = await linuxDesktopDoctorChecks(
      hostIsLinux: true,
      probe: _fake({
        'uname -m': const ToolProbeResult(ran: true, exitCode: 0, stdout: 'x86_64\n'),
        'flutter --version': const ToolProbeResult(
          ran: true,
          exitCode: 0,
          stdout: 'Flutter 3.35.0\n',
        ),
        'flutter devices --machine': const ToolProbeResult(
          ran: true,
          exitCode: 0,
          stdout:
              '[{"name":"linux-phone","id":"emulator-5554","targetPlatform":"android","emulator":true}]',
        ),
        'clang --version': const ToolProbeResult(ran: true, exitCode: 0, stdout: 'clang\n'),
        'cmake --version': const ToolProbeResult(ran: true, exitCode: 0, stdout: 'cmake\n'),
        'ninja --version': const ToolProbeResult(ran: true, exitCode: 0, stdout: '1.0\n'),
        'pkg-config --exists gtk+-3.0': const ToolProbeResult(ran: true, exitCode: 0),
        'pkg-config --modversion gtk+-3.0': const ToolProbeResult(ran: true, exitCode: 0, stdout: '3\n'),
        'sh -c printf \'%s\\n\' \'int main(){return 0;}\' | clang++ -x c++ - -o /dev/null -lstdc++':
            const ToolProbeResult(ran: true, exitCode: 0),
      }),
    );
    expect(report.ok, isFalse);
    expect(report.blocking, isTrue);
    expect(report.capabilities['linux_device'], isFalse);
  });

  test('Linux fixtures: missing pkg-config is blocking with diagnostic', () async {
    final report = await linuxDesktopDoctorChecks(
      hostIsLinux: true,
      probe: _fake({
        'uname -m': const ToolProbeResult(ran: true, exitCode: 0, stdout: 'x86_64\n'),
        'flutter --version': const ToolProbeResult(ran: true, exitCode: 0, stdout: 'Flutter\n'),
        'flutter devices --machine': const ToolProbeResult(
          ran: true,
          exitCode: 0,
          stdout: '[{"id":"linux","targetPlatform":"linux","emulator":false}]',
        ),
        'clang --version': const ToolProbeResult(ran: true, exitCode: 0, stdout: 'clang\n'),
        'cmake --version': const ToolProbeResult(ran: true, exitCode: 0, stdout: 'cmake\n'),
        'ninja --version': const ToolProbeResult(ran: true, exitCode: 0, stdout: '1.0\n'),
        'pkg-config --exists gtk+-3.0': const ToolProbeResult(
          ran: false,
          missing: true,
        ),
      }),
    );
    expect(report.ok, isFalse);
    expect(report.lines.join('\n'), contains('pkg-config: not on PATH'));
  });

  test('Linux fixtures: probe timeout is not a crash', () async {
    final report = await linuxDesktopDoctorChecks(
      hostIsLinux: true,
      probe: _fake({
        'uname -m': const ToolProbeResult(
          ran: false,
          timedOut: true,
          errorMessage: 'deadline (5s)',
        ),
      }),
    );
    expect(report.ok, isFalse);
    expect(report.lines.join('\n'), contains('uname: timed out'));
  });
}
