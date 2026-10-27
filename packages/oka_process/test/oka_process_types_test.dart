import 'package:oka_process/oka_process.dart';
import 'package:test/test.dart';

void main() {
  group('ProcessIdentityToken', () {
    test('equality uses pid, startTime, marker, and sessionId', () {
      final t = DateTime.utc(2026, 10, 26, 12);
      final a = ProcessIdentityToken(
        pid: 42,
        startTime: t,
        marker: 'm',
        sessionId: 7,
      );
      final b = ProcessIdentityToken(
        pid: 42,
        startTime: t,
        marker: 'm',
        sessionId: 7,
      );
      final c = ProcessIdentityToken(
        pid: 43,
        startTime: t,
        marker: 'm',
        sessionId: 7,
      );
      expect(a, b);
      expect(a == c, isFalse);
    });
  });

  group('ObservationBudget', () {
    test('defaults is two seconds', () {
      expect(ObservationBudget.defaults.duration, const Duration(seconds: 2));
    });

    test('validatePositive rejects zero', () {
      expect(
        () => const ObservationBudget(Duration.zero).validatePositive(),
        throwsArgumentError,
      );
    });
  });

  group('SettlementResult', () {
    test('StopReceipt reflects settled state', () {
      final receipt = StopReceipt(
        identity: ProcessIdentityToken(
          pid: 1,
          startTime: DateTime.utc(2026),
          marker: 'm',
          sessionId: 1,
        ),
        settlement: const SettlementSettled(exitCode: 0),
      );
      expect(receipt.isSettled, isTrue);
    });

    test('unsettled receipt', () {
      final receipt = StopReceipt(
        identity: ProcessIdentityToken(
          pid: 1,
          startTime: DateTime.utc(2026),
          marker: 'm',
          sessionId: 1,
        ),
        settlement: const SettlementUnsettled('observation timed out'),
      );
      expect(receipt.isSettled, isFalse);
    });
  });

  group('ProcessSessionBackendKind', () {
    test('wire names', () {
      expect(ProcessSessionBackendKind.posixPerl.wireName, 'posix-perl');
      expect(ProcessSessionBackendKind.posixNative.wireName, 'posix-native');
    });
  });

  group('posix-perl backend', () {
    test('launch and stop sleep target', () async {
      final backend = PosixPerlProcessSessionBackend();
      final handle = await backend.launch(
        const OwnedProcessLaunchSpec(
          executable: 'sleep',
          arguments: ['3600'],
        ),
      );
      expect(handle.leaderIdentity.pid, greaterThan(0));
      expect(handle.leaderIdentity.marker, isNotEmpty);
      expect(handle.leaderIdentity.sessionId, greaterThan(0));
      final receipt = await backend.stop(handle);
      expect(receipt.isSettled, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
