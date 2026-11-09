import 'package:oka_dart_kernel/src/gate/linux_subreaper_drain_receipt.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips drain diag control line', () {
    final line = SubreaperDrainReceipt(
      phase: 'enumerate',
      remainingMs: 1200,
      observations: const ['42:Z:sleep', '43:S:dart'],
      errors: const ['ps unavailable'],
      reapedZombies: 1,
      enumerateSource: '/proc',
    ).toControlLine();
    final parsed = parseSubreaperDrainDiag(line);
    expect(parsed, isNotNull);
    expect(parsed!.phase, 'enumerate');
    expect(parsed.remainingMs, 1200);
    expect(parsed.enumerateSource, '/proc');
    expect(parsed.reapedZombies, 1);
    expect(parsed.observations, ['42:Z:sleep', '43:S:dart']);
    expect(parsed.errors, ['ps unavailable']);
  });
}
