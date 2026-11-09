import 'dart:convert';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

import 'support/fake_daemon_transport.dart';

void main() {
  test('single oversized stderr line is truncated, ring keeps prior lines', () async {
    final t = FakeDaemonTransport();
    final adapter = FlutterDaemonAdapter(transport: t);
    t.emitStderr('short line one\n');
    final huge = 'x' * 5000;
    t.emitStderr('$huge\n');
    t.emitStderr('short line three\n');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final tail = adapter.stderrTail;
    expect(tail.length, greaterThanOrEqualTo(2));
    expect(tail.first, 'short line one');
    expect(tail.last, 'short line three');
    expect(
      tail.any((line) => line.contains('[truncated]')),
      isTrue,
      reason: 'oversized line must shrink instead of evicting the ring',
    );
    for (final line in tail) {
      expect(utf8.encode(line).length, lessThanOrEqualTo(2048 + 64));
    }
    adapter.dispose();
  });
}
