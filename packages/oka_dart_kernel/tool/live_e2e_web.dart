/// Live-e2e web leg as a Dart driver (ADR-0036 Tier 1): flutter
/// web-server + DDK in Chrome, dwds reloadSources (oka-driven) + CDP
/// page probes — bring-up, baseline reset, patch, verify, teardown in
/// one process. Proves: probe flip + hold (no restart) + receipt ok.
///
/// Env: LIVE_APP_ROOT (last_answer), FLUTTER_BIN, CHROME_BIN.
/// Exit 0 = leg PASS.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';

// ignore_for_file: avoid_print, prefer_const_declarations, prefer_const_constructors, unnecessary_raw_strings, unused_local_variable

final home = Platform.environment['HOME']!;
final appRoot = Platform.environment['LIVE_APP_ROOT'] ??
    '$home/xs/storage_problem/last_answer';
final flutterBin = Platform.environment['FLUTTER_BIN'] ??
    '$home/fvm/default/bin/flutter';
final chromeBin = Platform.environment['CHROME_BIN'] ??
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const cdpPort = 9223;
const webPort = 8187;

const unitFile = 'packages/headless_core/lib/src/fractional_order.dart';
final toolDir = File.fromUri(Platform.script).parent.path;
final repoRoot = File.fromUri(Platform.script).parent.parent.path;

Future<void> main() async {
  final targetFile = File('$appRoot/$unitFile');
  final original = await targetFile.readAsString();
  final chromeProfile = '/tmp/oka-chrome-profile';
  final webPidFile = '/tmp/oka_live_web.pid';
  Process? flutterRun;
  var failed = false;
  try {
    final chromeProfileDir = Directory(chromeProfile);
    if (chromeProfileDir.existsSync()) {
      chromeProfileDir.deleteSync(recursive: true);
    }
    flutterRun = await Process.start(flutterBin, [
      'run',
      '-d',
      'web-server',
      '--web-hostname',
      '127.0.0.1',
      '--web-port',
      '$webPort',
      '--pid-file=$webPidFile',
    ], workingDirectory: appRoot);
    final lines = <String>[];
    flutterRun.stdout.transform(const Utf8Decoder()).listen(lines.add);
    flutterRun.stderr.transform(const Utf8Decoder()).listen(lines.add);

    await waitLine(lines, 'is being served at', const Duration(minutes: 8),
        'web server');
    await Process.start(chromeBin, [
      '--user-data-dir=$chromeProfile',
      '--remote-debugging-port=$cdpPort',
      '--no-first-run',
      '--no-default-browser-check',
      'http://127.0.0.1:$webPort',
    ]);
    await waitLine(lines, 'A Dart VM Service', const Duration(minutes: 8),
        'dwds debug service');
    final uriLine =
        lines.firstWhere((l) => l.contains('A Dart VM Service'));
    final httpBase =
        RegExp(r'http://[^ \r\n]+').firstMatch(uriLine)!.group(0)!.trim();
    final ws =
        '${httpBase.replaceFirst('http', 'ws').replaceAll(RegExp(r'/+$'), '')}/ws';
    final cdpWs = await pageTabWs(cdpPort, 'Last Answer');

    // Clean baseline: the page must boot from the UNPATCHED bundle.
    final fpid = File(webPidFile).readAsStringSync().trim();
    Process.runSync('kill', ['-USR1', fpid]);
    await Future<void>.delayed(const Duration(seconds: 10));
    await Process.run('dart', ['$toolDir/cdp_eval.dart', cdpWs, 'location.reload(true)'],
        workingDirectory: repoRoot);
    await Future<void>.delayed(const Duration(seconds: 15));
    final reset = await Process.run('dart', ['$toolDir/web_reset.dart', '$cdpPort', 'b'],
        workingDirectory: repoRoot);
    if (reset.exitCode != 0) {
      throw StateError('baseline reset failed: ${reset.stderr}');
    }

    final receipt = await runLivePatch(
      LivePatchSpec(
        revision: 'rev-b',
        unit: 'fractional_order',
        patches: [
          PatchEdit(
            file: unitFile,
            find: "const String _alphabet = 'abcdefghijklmnopqrstuvwxyz';",
            replace: "const String _alphabet = 'acbdefghijklmnopqrstuvwxyz';",
          ),
        ],
        targets: [
          TargetSpec(
            kind: 'web',
            id: 'chrome',
            ws: ws,
            pidFile: webPidFile,
            signal: 'USR1',
            settleMs: 5000,
            cdp: cdpWs,
          ),
        ],
        probes: const [
          ProbeSpec(
            library: 'fractional_order.dart',
            expression: "fractionalBetween('a', null)",
            expect: 'c',
            webExpression:
                "String(dartDevEmbedder.importLibrary('package:headless_core/src/fractional_order.dart').fractionalBetween('a', null))",
          ),
          ProbeSpec(
            library: 'lastanswer/main.dart',
            expression: 'identityHashCode(main)',
            webExpression: 'String(performance.timeOrigin)',
            hold: true,
          ),
        ],
      ),
      compile: (request) async => DeltaArtifact(
          path: 'web-advisory.dill', bytes: 0), // dwds recompiles itself
      root: appRoot,
      onEvent: (e) => print('live: ${e.why}'),
    );
    print(receipt.describe());
    if (!receipt.ok) throw StateError('live patch refused');
    print('web: live patch OK');
  } catch (e) {
    failed = true;
    print('web: FAILED — $e');
  } finally {
    await targetFile.writeAsString(original);
    Process.runSync('pkill', ['-f', 'oka-chrome-profile']);
    if (File(webPidFile).existsSync()) {
      Process.runSync('kill', [File(webPidFile).readAsStringSync().trim()]);
    }
    flutterRun?.kill();
  }
  exit(failed ? 1 : 0);
}

Future<void> waitLine(
    List<String> lines, String pattern, Duration timeout, String what) async {
  final sw = Stopwatch()..start();
  while (!lines.join('\n').contains(pattern)) {
    if (sw.elapsed > timeout) {
      throw StateError('timeout waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// Finds the page tab titled [title] in Chrome's DevTools HTTP API.
Future<String> pageTabWs(int port, String title) async {
  final client = HttpClient();
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.1:$port/json/list'));
      final response = await request.close();
      final tabs = (jsonDecode(await response
              .transform(const Utf8Decoder())
              .join()) as List)
          .cast<Map<dynamic, dynamic>>();
      for (final t in tabs) {
        if (t['type'] == 'page' && (t['title'] as String? ?? '') == title) {
          return t['webSocketDebuggerUrl'] as String;
        }
      }
    } on Object {
      // Chrome not ready yet.
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError('page tab "$title" never appeared on :$port');
}
