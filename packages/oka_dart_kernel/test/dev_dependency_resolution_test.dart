import 'dart:io';
import 'package:test/test.dart';
import '../tool/oka_run_dev.dart';

void main() {
  test('fast dependency process EOF never stalls after exit', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final lines = <String>[];
    await resolveDevDependencies(
      Directory.current.path,
      '/usr/bin/true',
      lines.add,
    ).timeout(const Duration(seconds: 2));
    expect(lines.last, contains('ok'));
  });
  test('failed dependency process returns named refusal', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    await expectLater(
      resolveDevDependencies(
        Directory.current.path,
        '/usr/bin/false',
        (_) {},
      ).timeout(const Duration(seconds: 2)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'failure',
          contains('pub get --offline failed'),
        ),
      ),
    );
  });
}
