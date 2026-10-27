@TestOn('vm && (linux || mac-os)')
library;

import 'dart:io';

import 'package:oka_process/src/session_control_binding.dart';
import 'package:test/test.dart';

void main() {
  test('bind fails closed when chmod 700 fails', () async {
    var chmodCalls = 0;
    String? tempPath;
    await expectLater(
      SessionControlBinding.bind(
        chmodRunner: (path) async {
          chmodCalls++;
          tempPath = path;
          expect(Directory(path).existsSync(), isTrue);
          return ProcessResult(0, 1, '', 'chmod failed');
        },
      ),
      throwsA(
        isA<SessionControlBindException>().having(
          (e) => e.message,
          'message',
          contains('chmod 700 failed'),
        ),
      ),
    );
    expect(chmodCalls, 1);
    expect(tempPath, isNotNull);
    expect(Directory(tempPath!).existsSync(), isFalse);
  });
}
