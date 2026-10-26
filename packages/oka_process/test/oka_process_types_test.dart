import 'package:oka_process/oka_process.dart';
import 'package:test/test.dart';

void main() {
  group('ProcessIdentityToken', () {
    test('equality uses pid and startTime', () {
      final t = DateTime.utc(2026, 10, 26, 12);
      final a = ProcessIdentityToken(pid: 42, startTime: t);
      final b = ProcessIdentityToken(pid: 42, startTime: t);
      final c = ProcessIdentityToken(pid: 43, startTime: t);
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

  group('backends', () {
    test('posix-perl launch is unsupported until P0', () {
      final backend = PosixPerlProcessSessionBackend();
      expect(
        backend.launch(const OwnedProcessLaunchSpec(executable: '/bin/true')),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
