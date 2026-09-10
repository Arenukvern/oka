// ADR-0018 L1 — the teardown contract: reserved lifecycle verbs, the
// Target.compileTeardown default, and the EmulatorTarget stopOnExit
// composition (the CLI verbs' logic lives in oka_core's surface tests;
// this file pins the composition contract).
import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

class _BareTarget extends Target {
  const _BareTarget();

  @override
  String get name => 'bare';

  @override
  String get description => 'bare';

  @override
  List<BuildStep> compile(final BuildContext ctx) => const [];
}

BuildContext _ctx() => const BuildContext(
      projectPath: '/tmp/x',
      buildDir: '/tmp/x/.oka_cache',
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: '/tmp/x/.oka_cache',
    );

void main() {
  test('lifecycle verbs are reserved (no target can shadow them)', () {
    expect(validateTargetName('processes'), isNotNull);
    expect(validateTargetName('stop'), isNotNull);
    // The reserved set itself carries both.
    expect(reservedCliVerbs, containsAll(['processes', 'stop']));
  });

  test('Target.compileTeardown defaults to no teardown', () {
    expect(const _BareTarget().compileTeardown(_ctx()), isEmpty);
  });

  test('EmulatorTarget default keeps the long-lived posture (no teardown)',
      () {
    expect(const EmulatorTarget().compileTeardown(_ctx()), isEmpty);
  });

  test('EmulatorTarget stopOnExit composes StopEmulatorStep', () {
    final steps = const EmulatorTarget(stopOnExit: true).compileTeardown(
      _ctx(),
    );
    expect(steps, hasLength(1));
    expect(steps.single.name, 'stop-emulator');
  });

  test('EmulatorTarget.compile still carries exactly the boot chain', () {
    final steps = const EmulatorTarget().compile(_ctx());
    expect(steps.map((final s) => s.name), [
      'ensure-avd',
      'boot-emulator',
    ]);
  });
}
