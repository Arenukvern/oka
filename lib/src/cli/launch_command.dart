import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;

/// `oka launch` — device smoke test: install the latest APK, launch it, wait,
/// then scan logcat for the classic failure signatures.
///
/// This closes the feedback loop that static checks cannot: a build can be
/// structurally valid while the app dies on launch (e.g. a plugin class
/// missing from the DEX kills `GeneratedPluginRegistrant` and silently
/// unregisters ALL plugins — the UI then fails with channel errors).
///
/// Failure signatures scanned:
/// - `FATAL EXCEPTION` / `Unhandled Exception` — Dart or platform crash
/// - `NoClassDefFoundError` — missing runtime class (dependency gap)
/// - `could not find or invoke the GeneratedPluginRegistrant` — registrant
///   failed → every plugin unregistered
/// - `Error registering plugin` — single-plugin registration failure
/// - `channel-error` / `Unable to establish connection on channel` — plugin
///   not registered while Dart calls into it
class LaunchCommand {
  static const _failureSignatures = <String, String>{
    'fatal-exception': 'FATAL EXCEPTION',
    'unhandled-dart-exception': 'Unhandled Exception',
    'missing-class': 'NoClassDefFoundError',
    'registrant-missing': 'could not find or invoke the GeneratedPluginRegistrant',
    'plugin-register-failed': 'Error registering plugin',
    'channel-error': 'channel-error',
    'pigeon-channel-missing': 'Unable to establish connection on channel',
  };

  Future<void> run(List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'apk',
        help: 'APK to install (default: newest .oka_cache/build/*/app-*.apk)',
      )
      ..addOption('package', help: 'Override package name (default: badging)')
      ..addOption(
        'activity',
        help: 'Override launchable activity (default: badging)',
      )
      ..addFlag(
        'no-install',
        negatable: false,
        help: 'Skip adb install (app must already be on the device)',
      )
      ..addOption(
        'wait',
        help: 'Seconds to wait before the logcat scan',
        defaultsTo: '10',
      );
    final results = parser.parse(args);
    final waitSec = int.tryParse(results['wait'] as String) ?? 10;
    final adb = await _findAdb();

    final apk = await _resolveApk(results['apk'] as String?);
    final badging = await _badging(apk);
    final packageName =
        (results['package'] as String?) ?? badging['package'];
    final activity =
        (results['activity'] as String?) ?? badging['launchable-activity'];
    if (packageName == null || packageName.isEmpty) {
      print('❌ Could not determine package name — pass --package.');
      exit(2);
    }
    if (activity == null || activity.isEmpty) {
      print('❌ Could not determine launchable activity — pass --activity.');
      exit(2);
    }

    if (!(results['no-install'] as bool)) {
      print('📲 Installing ${p.basename(apk)} → $packageName');
      final install = await Process.run(adb, [
        'install',
        '-r',
        apk,
      ]);
      if (install.exitCode != 0 ||
          '${install.stdout}${install.stderr}'.contains('Failure')) {
        final output = '${install.stdout}${install.stderr}'.trim();
        if (output.contains('INCOMPATIBLE')) {
          print(
            '\n❌ Signing-key mismatch: the device already has this app '
            'installed with a different key. Never uninstall an app with '
            'user data — sign with the same key instead '
            '(android/key.properties).',
          );
        } else if (output.contains('not found') ||
            output.contains('no devices')) {
          print('\n❌ No device connected. Reconnect the phone and re-run.');
        } else {
          print('\n❌ Install failed:\n$output');
        }
        exit(1);
      }
      print('✅ Installed');
    }

    print('🚀 Starting $activity');
    // Clear the log buffer first — older runs (or other apps) must not
    // produce false failure signatures in the scan below.
    await Process.run(adb, ['logcat', '-c']);
    final start = await Process.run(adb, [
      'shell',
      'am',
      'start',
      '-n',
      '$packageName/$activity',
    ]);
    if (start.exitCode != 0) {
      stdout.write(start.stdout);
      stderr.write(start.stderr);
      exit(1);
    }

    print('⏳ Waiting ${waitSec}s before scanning logcat...');
    await Future<void>.delayed(Duration(seconds: waitSec));

    final pid = await _pidOf(adb, packageName);
    final scan = await _scanLogcat(adb);
    _report(packageName: packageName, pid: pid, scan: scan);
    final alive = pid != null && pid.isNotEmpty;
    final failed =
        scan.isNotEmpty || (!alive && !(results['no-install'] as bool));
    exit(failed ? 1 : 0);
  }

  Future<String> _findAdb() async {
    try {
      return await SdkLocator().findAdb();
    } on Exception {
      print('❌ adb not found — install platform-tools (oka get android-sdk)');
      exit(2);
    }
  }

  /// Newest APK across `.oka_cache/build/*/app-*.apk`, or [explicit].
  Future<String> _resolveApk(final String? explicit) async {
    if (explicit != null) {
      if (!File(explicit).existsSync()) {
        print('❌ not found: $explicit');
        exit(2);
      }
      return explicit;
    }
    final candidates = <String>[];
    final buildRoot = Directory(p.join(Directory.current.path, '.oka_cache', 'build'));
    if (buildRoot.existsSync()) {
      await for (final modeDir in buildRoot.list()) {
        if (modeDir is! Directory) continue;
        final aabDir = Directory(p.join(modeDir.path, 'aab'));
        final dirs = <Directory>[modeDir, if (aabDir.existsSync()) aabDir];
        for (final d in dirs) {
          await for (final f in d.list()) {
            if (f is File && p.basename(f.path).endsWith('.apk')) {
              candidates.add(f.path);
            }
          }
        }
      }
    }
    if (candidates.isEmpty) {
      print('❌ No APK found — run `oka build apk` first (or pass --apk).');
      exit(2);
    }
    candidates.sort(
      (final a, final b) => File(b).lastModifiedSync().compareTo(
            File(a).lastModifiedSync(),
          ),
    );
    return candidates.first;
  }

  /// Minimal `aapt2 dump badging` reader: package + launchable-activity.
  Future<Map<String, String>> _badging(final String apk) async {
    String? aapt2;
    try {
      aapt2 = await SdkLocator().findAapt2();
    } on Exception {
      return const {};
    }
    final r = await Process.run(aapt2, ['dump', 'badging', apk]);
    final out = <String, String>{};
    for (final line in (r.stdout as String).split('\n')) {
      if (line.startsWith('package:')) {
        final m = RegExp("name='([^']+)'").firstMatch(line);
        if (m != null) out['package'] = m.group(1)!;
      }
      if (line.startsWith('launchable-activity:')) {
        final m = RegExp("name='([^']+)'").firstMatch(line);
        if (m != null) out['launchable-activity'] = m.group(1)!;
      }
    }
    return out;
  }

  Future<String?> _pidOf(final String adb, final String packageName) async {
    final r = await Process.run(adb, ['shell', 'pidof', packageName]);
    return (r.stdout as String).trim();
  }

  /// Scans the device log buffers for failure signatures (full log, current
  /// boot: crashes rarely appear in `-b crash` alone when they are caught and
  /// logged as errors instead).
  Future<Map<String, String>> _scanLogcat(final String adb) async {
    final r = await Process.run(adb, ['logcat', '-d']);
    final log = '${r.stdout}${r.stderr}';
    final found = <String, String>{};
    for (final entry in _failureSignatures.entries) {
      if (log.toLowerCase().contains(entry.value.toLowerCase())) {
        found[entry.key] = entry.value;
      }
    }
    return found;
  }

  void _report({
    required final String packageName,
    required final String? pid,
    required final Map<String, String> scan,
  }) {
    print('');
    if (pid != null && pid.isNotEmpty) {
      print('✅ Process alive (pid $pid)');
    } else {
      print('💀 Process not running — it died after launch');
    }
    if (scan.isEmpty) {
      print('✅ No failure signatures in logcat');
    } else {
      print('⚠️  Failure signatures found in logcat:');
      for (final entry in scan.entries) {
        print('   - ${entry.key}: "${entry.value}"');
      }
      print('');
      print('   Follow up with:');
      print('     adb logcat -d | grep -iE "FATAL|NoClassDefFound|registering"');
      print('   Docs: docs/guides/gradle_migration.md (diagnosis section)');
    }
  }
}
