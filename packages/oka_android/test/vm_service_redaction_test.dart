import 'package:oka_android/src/dev/vm_service_redaction.dart';
import 'package:test/test.dart';

void main() {
  const secret = 'XZgHLBJKpIA=';

  group('redactVmServiceAuthInString', () {
    test('redacts ws VM service URI auth segment', () {
      final raw = 'ws://127.0.0.1:65462/$secret/ws';
      final redacted = redactVmServiceAuthInString(raw);
      expect(redacted, isNot(contains(secret)));
      expect(redacted, contains(vmServiceAuthRedacted));
      expect(redacted, 'ws://127.0.0.1:65462/$vmServiceAuthRedacted/ws');
    });

    test('redacts http device announcement URI', () {
      final raw = 'http://127.0.0.1:43239/$secret/';
      final redacted = redactVmServiceAuthInString(raw);
      expect(redacted, isNot(contains(secret)));
      expect(redacted, contains(vmServiceAuthRedacted));
    });

    test('leaves non-vm strings unchanged', () {
      const plain = 'flutter attach exited before app.started';
      expect(redactVmServiceAuthInString(plain), plain);
    });
  });

  group('redactVmServiceAuthDeep', () {
    test('redacts nested wsUri in event ring maps', () {
      const secret = 'AbCdEfGh=';
      final input = {
        'machineEventRing': [
          {
            'event': 'app.debugPort',
            'params': {
              'wsUri': 'ws://127.0.0.1:1/$secret/ws',
            },
          },
        ],
      };
      final out = redactVmServiceAuthDeep(input) as Map;
      final ring = out['machineEventRing'] as List;
      final params = (ring.first as Map)['params'] as Map;
      expect('${params['wsUri']}', isNot(contains(secret)));
    });
  });
}
