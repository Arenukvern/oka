import 'dart:async';
import 'dart:io';

import 'package:oka_dart_kernel/src/gate/dev_gate_signals.dart';
import 'package:test/test.dart';

void main() {
  test('signal cleanup runs at most once under concurrent triggers', () async {
    var calls = 0;
    final gate = DevGateSignalCoordinator(
      onSignal: () async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      },
    );
    await Future.wait([
      gate.invokeForTest(ProcessSignal.sigterm),
      gate.invokeForTest(ProcessSignal.sigterm),
    ]);
    expect(calls, 1);
  });
}
