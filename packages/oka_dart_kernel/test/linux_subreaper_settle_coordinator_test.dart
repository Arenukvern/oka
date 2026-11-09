import 'package:oka_dart_kernel/src/gate/linux_subreaper_settle_coordinator.dart';
import 'package:test/test.dart';

void main() {
  test('settleOnce shares one cached future for overlapping callers', () async {
    final coordinator = LinuxSubreaperSettleCoordinator();
    var invokeCount = 0;
    Future<bool> body() async {
      invokeCount++;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      return true;
    }

    final a = coordinator.settleOnce(body);
    final b = coordinator.settleOnce(body);
    final c = coordinator.settleOnce(body);
    final results = await Future.wait([a, b, c]);
    expect(invokeCount, 1);
    expect(results, everyElement(isTrue));
  });
}
