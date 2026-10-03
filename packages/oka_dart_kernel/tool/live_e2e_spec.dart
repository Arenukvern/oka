/// Writes the per-leg `LivePatchSpec` JSON for `gate_live_e2e.sh`
/// (ADR-0036 Tier 0: specs are Dart values; JSON is only the wire form).
///
/// Usage:
/// ```
/// dart tool/live_e2e_spec.dart <leg> <out.json> --app=<root> \
///   [--ws=<uri>] [--http=<uri>] [--cdp=<uri>] [--pid-file=<path>]
/// ```
/// Legs: `mac-vm`, `linux`, `android`, `web`.
/// Also: `patch-android-signing <appRoot>` — the android leg's known-good
/// build fix (debug signing), applied and reverted by the gate.
library;

import 'dart:convert';
import 'dart:io';

// ignore_for_file: avoid_print

Future<void> main(List<String> args) async {
  if (args.length >= 2 && args.first == 'patch-android-signing') {
    await _patchAndroidSigning(args[1]);
    return;
  }
  if (args.length < 3) {
    throw StateError('usage: live_e2e_spec.dart <leg> <out.json> --app=<root>');
  }
  final leg = args[0];
  final out = args[1];
  String opt(String name) => args
      .where((a) => a.startsWith('--$name='))
      .map((a) => a.substring(name.length + 3))
      .first;
  final app = opt('app');
  final spec = switch (leg) {
    'mac-vm' || 'linux' => _vmLeg(leg, app, opt('ws')),
    'android' => _androidLeg(app, opt('ws'), opt('http')),
    'web' => _webLeg(app, opt('ws'), opt('pid-file'), opt('cdp')),
    _ => throw StateError('unknown leg: $leg'),
  };
  await File(out).writeAsString(const JsonEncoder.withIndent('  ').convert(spec));
  print('spec: $out');
}

Map<String, Object?> _vmLeg(String leg, String app, String ws) => {
      'revision': 'rev-b',
      'unit': 'doc_replica_store',
      'patches': [
        {
          'file': '$app/packages/headless_core/lib/src/doc_replica_store.dart',
          'find': "this.dir = 'doc_replicas',",
          'replace': "this.dir = 'doc_replicas_live',",
        }
      ],
      'targets': [
        {'kind': 'vm', 'id': leg == 'mac-vm' ? 'mac-vm' : 'linux-amd64', 'ws': ws}
      ],
      'probes': [
        {
          'library': 'oka_kernel_driver.dart',
          'expression': 'storeLabel()',
          'expect': 'doc_replicas_live',
        },
        {
          'library': 'oka_kernel_driver.dart',
          'expression': 'identityHashCode(storeLabel)',
          'hold': true,
        }
      ],
    };

Map<String, Object?> _androidLeg(String app, String ws, String http) => {
      'revision': 'rev-b',
      'unit': 'fractional_order',
      'patches': [
        {
          'file': '$app/packages/headless_core/lib/src/fractional_order.dart',
          'find': "const String _alphabet = 'abcdefghijklmnopqrstuvwxyz';",
          'replace': "const String _alphabet = 'acbdefghijklmnopqrstuvwxyz';",
        }
      ],
      'targets': [
        {
          'kind': 'vm',
          'id': 'android-emulator',
          'ws': ws,
          'http': http,
          'devfs': 'oka_live',
        }
      ],
      'probes': [
        {
          'library': 'fractional_order.dart',
          'expression': "fractionalBetween('a', null)",
          'expect': 'c',
        },
        {
          'library': 'lastanswer/main.dart',
          'expression': 'identityHashCode(main)',
          'hold': true,
        }
      ],
    };

Map<String, Object?> _webLeg(String app, String ws, String pidFile, String cdp) =>
    {
      'revision': 'rev-b',
      'unit': 'fractional_order',
      'patches': [
        {
          'file': '$app/packages/headless_core/lib/src/fractional_order.dart',
          'find': "const String _alphabet = 'abcdefghijklmnopqrstuvwxyz';",
          'replace': "const String _alphabet = 'acbdefghijklmnopqrstuvwxyz';",
        }
      ],
      'targets': [
        {
          'kind': 'web',
          'id': 'chrome',
          'ws': ws,
          'pidFile': pidFile,
          'signal': 'USR1',
          'settleMs': 5000,
          'cdp': cdp,
        }
      ],
      'probes': [
        {
          'library': 'fractional_order.dart',
          'expression': "fractionalBetween('a', null)",
          'expect': 'c',
          'webExpression':
              "String(dartDevEmbedder.importLibrary('package:headless_core/src/fractional_order.dart').fractionalBetween('a', null))",
        },
        {
          'library': 'lastanswer/main.dart',
          'expression': 'identityHashCode(main)',
          'webExpression': 'String(performance.timeOrigin)',
          'hold': true,
        }
      ],
    };

Future<void> _patchAndroidSigning(String appRoot) async {
  final p = File('$appRoot/android/app/build.gradle.kts');
  final s = await p.readAsString();
  const old = '''    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("release")
        }''';
  const replacement = '''    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }''';
  if (!s.contains(old)) {
    throw StateError('debug signing block not found');
  }
  await p.writeAsString(s.replaceFirst(old, replacement));
  print('android signing: debug (patched; gate reverts on exit)');
}
