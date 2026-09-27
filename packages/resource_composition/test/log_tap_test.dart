import 'dart:async';

// `allOf` here is the matcher; the readiness combinator is unused below.
import 'package:resource_composition/resource_composition.dart' hide allOf;
import 'package:test/test.dart';

void main() {
  test('ring buffer drops oldest beyond the bound', () {
    final tap = LogTap(maxLines: 3)..add('a')..add('b')..add('c')..add('d');
    expect(tap.tail(10), ['b', 'c', 'd']);
    expect(tap.tail(2), ['c', 'd']);
  });

  test('firstMatch and count read the buffered window', () {
    final tap = LogTap()
      ..add('starting...')
      ..add('Dart VM Service listening on ws://127.0.0.1:8123/token')
      ..add('ready');
    expect(tap.firstMatch(RegExp('Dart VM Service')), contains('ws://'));
    expect(tap.count('ready'), 1);
  });

  test('waitFor finds an already-buffered line', () async {
    final tap = LogTap()..add('vm service ws://127.0.0.1:8123/abc');
    final line = await tap.waitFor(
      RegExp(r'ws://\S+'),
      timeout: const Duration(milliseconds: 500),
    );
    expect(line, contains('8123'));
  });

  test('waitFor subscribes to the live stream for future lines', () async {
    final tap = LogTap();
    final future = tap.waitFor(
      RegExp('ready'),
      timeout: const Duration(seconds: 2),
    );
    Future<void>.delayed(
      const Duration(milliseconds: 20),
      () => tap.add('ready now'),
    );
    expect(await future, 'ready now');
  });

  test('waitFor timeout embeds the tail for debugging', () async {
    final tap = LogTap(name: 'app')..add('line-1')..add('line-2');
    await expectLater(
      tap.waitFor('never', timeout: const Duration(milliseconds: 100)),
      throwsA(
        isA<TimeoutException>().having(
          (final e) => e.message,
          'message',
          allOf(contains('app'), contains('line-2')),
        ),
      ),
    );
  });

  test('close stops accepting lines and closes the stream', () async {
    final tap = LogTap()..add('before');
    await tap.close();
    tap.add('after');
    expect(tap.tail(10), ['before']);
    expect(tap.isClosed, isTrue);
  });
}
