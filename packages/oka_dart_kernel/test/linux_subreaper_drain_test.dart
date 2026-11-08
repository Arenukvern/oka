import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/src/gate/linux_subreaper_drain.dart';
import 'package:test/test.dart';

final class _AlwaysUnavailableProbe implements ProcessTreeProbe {
  const _AlwaysUnavailableProbe();

  @override
  Future<ProcessTree?> enumerate(int rootPid) async => null;
}

void main() {
  test('unavailable listing is not verified settled', () async {
    final result = await drainSubreaperAdoptees(
      supervisorPid: 999_999,
      probe: const _AlwaysUnavailableProbe(),
      liveness: const HostProcessLiveness(),
      budget: const Duration(milliseconds: 50),
    );
    expect(result.settled, isFalse);
    expect(result.verified, isFalse);
    expect(result.notes, anyElement(contains('unavailable')));
  });
}
