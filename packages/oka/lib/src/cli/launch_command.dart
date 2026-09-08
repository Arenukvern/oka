import 'dart:io';

import 'package:args/args.dart';

import 'run_command.dart';

/// `oka launch` — CLI alias of the device target, `oka run device`
/// (ADR-0015: verbs never know platforms).
///
/// The device flow (install newest APK → launch → failure-signature scan)
/// is a *target* shipped by `oka_android` ([DeviceTarget], exported from the
/// barrel) and configured per project in the composition root
/// (`tool/oka_pipeline.dart: Oka(targets: [DeviceTarget(...)])`). This verb
/// contains no Android implementation logic: it resolves and dispatches
/// exactly like `oka run` does, keeping the historical spelling and its
/// portable flags
/// (`--device`/`-d`, `--verbose`) working.
class LaunchCommand {
  Future<void> run(final List<String> args) async {
    // Flags that moved behind the device target (ADR-0015): device-flow
    // options are typed target config now, not CLI flags. Fail with the
    // migration path instead of letting them leak into the dispatcher.
    const movedFlags = {'apk', 'package', 'activity', 'no-install', 'wait'};
    final moved = args
        .where(
          (final a) =>
              a.startsWith('--') &&
              movedFlags.contains(a.substring(2).split('=').first),
        )
        .toList();
    if (moved.isNotEmpty) {
      stderr.writeln(
        '❌ oka launch flags moved behind the device target (ADR-0015):\n'
        '   ${moved.join(' ')}\n'
        '\n'
        '   Configure the flow in the composition root instead '
        '(tool/oka_pipeline.dart):\n'
        '     Oka(targets: [DeviceTarget(apk: ..., package: ..., '
        'noInstall: true, waitSeconds: 15)])\n'
        '\n'
        '   Then run: oka run device   (or keep using: oka launch)',
      );
      exit(2);
    }

    final parser = ArgParser()
      ..addOption(
        'device',
        abbr: 'd',
        help: 'Device serial — required on multi-device hosts; '
            'forwarded to the device target',
      )
      ..addFlag('verbose', negatable: false, help: 'Verbose output')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');
    final results = parser.parse(args);
    if (results['help'] as bool) {
      _printUsage();
      return;
    }

    // Same dispatch path as `oka run device` — the device target is
    // resolved from the project entrypoint, its compiled steps validated,
    // then run. No platform logic here; `-d` is re-expressed in the
    // dispatcher's vocabulary (`--oka-target-arg device=<id>`).
    await RunCommand().run([
      'device',
      if ((results['device'] as String?)?.isNotEmpty ?? false) ...[
        '--oka-target-arg',
        'device=${results['device']}',
      ],
      if (results['verbose'] as bool) '--verbose',
      ...results.rest,
    ]);
  }
}

void _printUsage() {
  print('''
oka launch — alias of `oka run device` (ADR-0015)

Install the newest built APK, launch it, and scan the device log for
failure signatures. The flow is a project-declared target shipped by
oka_android; configure it in tool/oka_pipeline.dart:

  Oka(
    targets: [
      DeviceTarget(
        apk: '...',          // default: newest APK under .oka_cache/build/
        package: '...',      // default: read from APK metadata
        activity: '...',     // default: read from APK metadata
        noInstall: true,     // skip the install step
        waitSeconds: 15,     // delay before the log scan (default 10)
      ),
    ],
  )

Flags:
  -d, --device   Accepted for CLI compatibility (the target runs against
                 the connected device)
      --verbose  Verbose output
  -h, --help     Show this help
''');
}
