import 'dart:io';

import 'package:oka/src/doctor/linux_desktop_doctor.dart';
import 'package:test/test.dart';

ShellRunner _fake(Map<String, ProcessResult> table) => (
  executable,
  arguments, {
  environment,
}) async {
  final key = '$executable ${arguments.join(' ')}';
  return table[key] ?? ProcessResult(1, 127, '', 'not found: $key');
};

void main() {
  test('non-Linux host: advisory only, not blocking', () async {
    if (Platform.isLinux) {
      // Host-dependent; covered by integration on Linux CI.
      return;
    }
    final report = await linuxDesktopDoctorChecks();
    expect(report.applicable, isFalse);
    expect(report.blocking, isFalse);
    expect(report.lines.join('\n'), contains('not Linux'));
  });

  test('Linux fixtures: full OK when flutter+gtk+display present', () async {
    final report = await linuxDesktopDoctorChecks(
      hostIsLinux: true,
      run: _fake({
        'uname -m': ProcessResult(0, 0, 'x86_64\n', ''),
        'flutter --version': ProcessResult(
          0,
          0,
          'Flutter 3.35.0 • channel stable\n',
          '',
        ),
        'flutter devices --machine': ProcessResult(
          0,
          0,
          '[{"id":"linux","targetPlatform":"linux"}]',
          '',
        ),
        'pkg-config --exists gtk+-3.0': ProcessResult(0, 0, '', ''),
        'pkg-config --modversion gtk+-3.0': ProcessResult(0, 0, '3.24.41\n', ''),
      }),
    );
    expect(report.applicable, isTrue);
    expect(report.ok, isTrue);
    expect(report.blocking, isFalse);
    expect(report.capabilities['linux_device'], isTrue);
    expect(report.capabilities['gtk_dev'], isTrue);
  });

  test('Linux fixtures: missing linux device is blocking', () async {
    final report = await linuxDesktopDoctorChecks(
      hostIsLinux: true,
      run: _fake({
        'uname -m': ProcessResult(0, 0, 'x86_64\n', ''),
        'flutter --version': ProcessResult(0, 0, 'Flutter 3.35.0\n', ''),
        'flutter devices --machine': ProcessResult(0, 0, '[]', ''),
        'pkg-config --exists gtk+-3.0': ProcessResult(0, 0, '', ''),
        'pkg-config --modversion gtk+-3.0': ProcessResult(0, 0, '3.24.41\n', ''),
      }),
    );
    expect(report.ok, isFalse);
    expect(report.blocking, isTrue);
    expect(report.capabilities['linux_device'], isFalse);
  });
}
