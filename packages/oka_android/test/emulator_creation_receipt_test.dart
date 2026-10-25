import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  for (final scenario in [
    (name: 'diagnostic with confirmed creation', code: 0, listed: true, ok: true),
    (name: 'diagnostic without creation', code: 0, listed: false, ok: false),
    (name: 'failed create despite inventory', code: 1, listed: true, ok: false),
  ]) {
    test(scenario.name, () async {
      var listings = 0;
      final state = PipelineState();
      final step = EnsureAvdStep(
        avdName: 'owned-test',
        systemImage: 'system-images;android-36;google_apis;arm64-v8a',
        avdManagerPath: '/fake/avdmanager',
        runProcess: (_, args) async {
          if (args.first == 'list') {
            listings++;
            return ProcessResult(
              1,
              0,
              listings > 1 && scenario.listed ? 'Name: owned-test\n' : '',
              '',
            );
          }
          return ProcessResult(
            1,
            scenario.code,
            '',
            'Error: Could not load devices from /sdk/devices.xml',
          );
        },
      );
      final result = await step.run(
        const BuildContext(
          projectPath: '/tmp/owned-test',
          buildDir: '/tmp/owned-test/build',
          mode: BuildMode.debug,
          config: OkaConfig.empty,
        ),
        state,
      );
      expect(result.ok, scenario.ok);
      expect(state['emulator-avd'], scenario.ok ? 'owned-test' : isNull);
      expect(listings, scenario.code == 0 ? 2 : 1);
    });
  }
}
