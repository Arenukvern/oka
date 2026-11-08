import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/src/gate/owned_dev_session.dart';
import 'package:test/test.dart';

/// Proves `clean` stays false when ownership cannot be proven (would regress if
/// empty survivors implied success).
void main() {
  test('no snapshot + unreadable probe => clean and verified are false', () async {
    final dir = await Directory.systemTemp.createTemp('oka_owned_guard');
    addTearDown(() => dir.delete(recursive: true));
    final stub = '${dir.path}/stub.dart';
    await File(stub).writeAsString('''
import 'dart:io';
void main() {
  stdout.writeln('dev: ready');
  sleep(const Duration(hours: 1));
}
''');
    final session = await OwnedDevSession.start(
      workspace: dir.path,
      dartInvocation: [stub],
      useSubreaperSupervisor: false,
      treeProbe: const _UnreadableProbe(),
    );
    expect(await session.waitForPattern('dev: ready'), isTrue);
    final td = await session.teardown(quitGrace: const Duration(seconds: 1));
    expect(td.clean, isFalse);
    expect(td.verified, isFalse);
  });
}

final class _UnreadableProbe implements ProcessTreeProbe {
  const _UnreadableProbe();
  @override
  Future<ProcessTree?> enumerate(int rootPid) async => null;
}
