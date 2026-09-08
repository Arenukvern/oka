// ADR-0013/0015: invocation-time target overrides (`--oka-target-arg`,
// `oka launch -d`) — typed contract + DeviceTarget wiring.
import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  group('Target.applyInvocationArgs default', () {
    test('rejects any arg with an actionable message', () {
      const t = _NoArgsTarget();
      expect(
        () => t.applyInvocationArgs({'bogus': '1'}),
        throwsArgumentError,
      );
    });
  });

  group('DeviceTarget invocation args', () {
    test('accepts device=<serial> and returns a new value with it', () {
      const t = DeviceTarget(waitSeconds: 3);
      final applied = t.applyInvocationArgs({'device': ' R5CX '});
      expect(applied, isNot(same(t)));
      expect(applied.deviceId, 'R5CX');
      expect(t.deviceId, isNull, reason: 'targets are const values');
      // The compiled steps must carry the serial.
      final ctx = _ctx();
      final steps = applied.compile(ctx);
      final install = steps.whereType<InstallApkStep>().single;
      expect(install.deviceId, 'R5CX');
    });

    test('rejects unknown keys naming the accepted ones', () {
      const t = DeviceTarget();
      expect(
        () => t.applyInvocationArgs({'bogus': '1'}),
        throwsA(
          predicate(
            (final e) => e.toString().contains('device=<serial>'),
          ),
        ),
      );
    });

    test('compiled steps omit -s when no deviceId (single device)', () {
      const t = DeviceTarget();
      final steps = t.compile(_ctx());
      expect(steps.whereType<InstallApkStep>().single.deviceId, isNull);
    });
  });
}

BuildContext _ctx() => const BuildContext(
      projectPath: '/tmp/x',
      buildDir: '/tmp/x/.oka_cache',
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: '/tmp/x/.oka_cache',
    );

class _NoArgsTarget extends Target {
  const _NoArgsTarget();

  @override
  String get name => 'no-args';

  @override
  String get description => 'target without invocation args';

  @override
  List<BuildStep> compile(final BuildContext ctx) => const [];
}
