import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_android/oka_android.dart';

/// Dev command (ADR-0011): preflights a hot-reload session against the
/// newest oka-built debug APK.
///
/// H1 scope: parse-and-delegate only. The CLI parses flags and prints the
/// result of [checkDevSession] (in `oka_android`'s device layer, where all
/// session logic lives): session-manifest validation — refuses loudly on
/// flag mismatch, SDK drift, or a pre-manifest build — and flutter-binary
/// resolution from the *recorded* SDK path (never ambient PATH).
///
/// The daemon session itself (attach --machine, reload/restart dispatch,
/// TTY keyboard loop, `--json`/`--watch` agent streams) is H3/H4 and stays
/// out of this file until its checklist phase.
class DevCommand {
  Future<void> run(final List<String> args) async {
    final parser = ArgParser()
      ..addOption('device', abbr: 'd', help: 'Target device ID')
      ..addOption(
        'target',
        help: 'Flutter entrypoint to request (validated against the '
            'recorded session manifest)',
      )
      ..addMultiOption(
        'dart-define',
        help: 'Additional KEY=VALUE dart-define (validated against the '
            'recorded session manifest)',
      )
      ..addOption(
        'dart-define-from-file',
        help: 'JSON file with KEY: VALUE defines (validated against the '
            'recorded session manifest)',
      )
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Verbose output')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');

    final results = parser.parse(args);
    if (results['help'] as bool) {
      _printUsage(parser);
      return;
    }

    print('🚀 Oka Development Mode\n');

    // H1 preflight: manifest validation + recorded-SDK binary resolution.
    final check = await checkDevSession(
      projectPath: Directory.current.path,
      targetFile: (results['target'] as String?)?.trim(),
      dartDefinePairs: results['dart-define'] as List<String>,
      dartDefineFromFile: results['dart-define-from-file'] as String?,
    );

    check.lines.forEach(print);
    if (!check.ok) {
      stderr.writeln(check.refusal);
      exit(1);
    }

    print('');
    print('✅ Session manifest validated — the dev loop can safely attach.');
    print('');
    print('Next (ADR-0011 H3, in flight):');
    print('  • flutter attach --machine session driven by oka');
    print('  • hot reload via the flutter_tools daemon protocol');
    print('');
    print('Meanwhile:');
    print('  1. oka build apk --debug');
    print('  2. oka run device (install, launch, failure-signature scan)');
    print('  3. flutter attach');
  }
}

void _printUsage(final ArgParser parser) {
  print('oka dev — validate a hot-reload session against the newest '
      'oka-built debug APK (ADR-0011)\n');
  print('Usage: oka dev [options]\n');
  print(parser.usage);
  print('''
The session manifest (run_session.json, recorded by `oka build apk --debug`)
is validated against the requested flags; a mismatch refuses with the exact
differing fields — a mismatched attach would corrupt the running app at
runtime instead of failing here. The session flutter binary always comes
from the SDK path recorded in the manifest, never PATH.
''');
}
