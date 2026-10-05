/// `oka run dev` runner — the converged dev session (ADR-0037 §6, amending
/// ADR-0011): build → launch → r/R over oka's own lanes.
///
///   r  hot RELOAD through oka's unit-delta lane: the changed file's
///      library is compiled by the app's own frontend and applied over the
///      VM service (DevFS + reloadSources + reassemble on flutter
///      desktop; dwds reloadSources on web) — the same mechanism the
///      production lanes use.
///   R  hot RESTART through the platform lane: the serving `flutter run`
///      session recompiles and restarts the app (oka's lane is a delta
///      lane; full restarts stay delegated until oka owns the resident
///      compiler).
///   q  quit. `--watch` additionally applies every saved file in the
///      watch set automatically (the invisible loop, ADR-0035).
///
///   dart tool/oka_run_dev.dart --project <dir> --platform macos|web \
///     [--device <id>] [--port <n>] [--open-browser] [--watch] \
///     [--unit <name>] [--probes <spec.json>] [--json]
///
/// Exit 0 only after a clean `q`. The published `oka` CLI delegates here
/// (`oka run dev`, same posture as `oka live`/`oka ship`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_mcp_harness/flutter_mcp_harness.dart';
import 'package:oka_update/oka_update.dart';

import 'flutter_delta.dart';

// ignore_for_file: avoid_print

const _usage = 'usage: oka run dev [--project <dir>] [--platform macos|web]\n'
    '  --device <id>       -d override (default: macos / web-server)\n'
    '  --port <n>          web-server port (default 8187)\n'
    '  --open-browser      web: launch Chrome with CDP for page probes\n'
    '  --watch             apply every saved file in the watch set\n'
    '  --unit <name>       receipt unit label (default: dev)\n'
    '  --probes <file>     JSON ProbeSpec array verified after each reload\n'
    '  --json              receipts as JSON lines\n'
    '\n'
    'Session commands (stdin): r [file] = hot reload (oka delta lane),\n'
    'R = hot restart (platform lane), q = quit.';

/// Parsed `oka run dev` arguments.
class RunDevArgs {
  const RunDevArgs({
    required this.project,
    this.platform = 'macos',
    this.device,
    this.port = 8187,
    this.openBrowser = false,
    this.watch = false,
    this.unit = 'dev',
    this.probesFile,
    this.flutterBin,
    this.jsonOut = false,
  });

  final String project;
  final String platform;
  final String? device;
  final int port;
  final bool openBrowser;
  final bool watch;
  final String unit;
  final String? probesFile;
  final String? flutterBin;
  final bool jsonOut;

  /// Null when the invocation is malformed; [error] then says why.
  static RunDevArgs? parse(List<String> args, {String? cwd}) {
    String? project = cwd;
    var platform = 'macos';
    String? device;
    var port = 8187;
    var openBrowser = false;
    var watch = false;
    var unit = 'dev';
    String? probesFile;
    String? flutterBin;
    var jsonOut = false;
    String? value(final String name, final String arg, final int i) {
      if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
      if (arg == '--$name' && i + 1 < args.length) return args[i + 1];
      return null;
    }

    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      final projV = value('project', a, i);
      if (projV != null) {
        project = projV;
        if (a == '--project') i++;
        continue;
      }
      final platV = value('platform', a, i);
      if (platV != null) {
        if (!{'macos', 'web'}.contains(platV)) return null;
        platform = platV;
        if (a == '--platform') i++;
        continue;
      }
      final devV = value('device', a, i);
      if (devV != null) {
        device = devV;
        if (a == '--device') i++;
        continue;
      }
      final portV = value('port', a, i);
      if (portV != null) {
        port = int.tryParse(portV) ?? -1;
        if (port <= 0) return null;
        if (a == '--port') i++;
        continue;
      }
      final probeV = value('probes', a, i);
      if (probeV != null) {
        probesFile = probeV;
        if (a == '--probes') i++;
        continue;
      }
      final flutV = value('flutter-bin', a, i);
      if (flutV != null) {
        flutterBin = flutV;
        if (a == '--flutter-bin') i++;
        continue;
      }
      final unitV = value('unit', a, i);
      if (unitV != null) {
        unit = unitV;
        if (a == '--unit') i++;
        continue;
      }
      switch (a) {
        case '--open-browser':
          openBrowser = true;
        case '--watch':
          watch = true;
        case '--json':
          jsonOut = true;
        default:
          return null; // unknown token
      }
    }
    if (project == null) return null;
    return RunDevArgs(
      project: project,
      platform: platform,
      device: device,
      port: port,
      openBrowser: openBrowser,
      watch: watch,
      unit: unit,
      probesFile: probesFile,
      flutterBin: flutterBin,
      jsonOut: jsonOut,
    );
  }
}

/// The owning `flutter run` session, narrowed to what the dev loop needs
/// (tests inject a fake).
abstract class DevApp {
  /// Tokenized VM-service HTTP base the session owns.
  Uri get vmUri;

  /// Sends a line to the serving tool's stdin (`r`/`R`/`q`).
  void write(String line);

  /// Waits for the next output line matching [pattern].
  Future<String> waitFor(Pattern pattern,
      {Duration timeout = const Duration(seconds: 90)});

  /// Graceful teardown (the tool's own quit, then escalation).
  Future<int> stop();
}

class _HarnessApp implements DevApp {
  _HarnessApp(this._app);
  final LaunchedApp _app;

  @override
  Uri get vmUri => _app.vmUri;

  @override
  void write(String line) {
    _app.process.stdin.writeln(line);
    _app.process.stdin.flush();
  }

  @override
  Future<String> waitFor(Pattern pattern,
          {Duration timeout = const Duration(seconds: 90)}) =>
      _app.stdout.waitFor(pattern, timeout: timeout);

  @override
  Future<int> stop() => _app.stop();
}

class _RawApp implements DevApp {
  _RawApp(this._process, this._tap, this._vmUri);
  final Process _process;
  final LogTap _tap;
  final Uri _vmUri;

  @override
  Uri get vmUri => _vmUri;

  @override
  void write(String line) {
    _process.stdin.writeln(line);
    _process.stdin.flush();
  }

  @override
  Future<String> waitFor(Pattern pattern,
          {Duration timeout = const Duration(seconds: 90)}) =>
      _tap.waitFor(pattern, timeout: timeout);

  @override
  Future<int> stop() async {
    await _tap.close();
    _process.kill(ProcessSignal.sigterm);
    return _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        Process.runSync('pkill', ['-P', '${_process.pid}']);
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
  }
}

/// Web boot: `flutter run -d web-server` announces the dwds VM service
/// only after a PAGE CONNECTS, so Chrome is launched between the server
/// line and the service line (the live_e2e_web ordering). Returns
/// (app, chrome process or null, page CDP ws or null).
Future<(DevApp, Process?, String?)> _launchWeb({
  required String project,
  required String flutterBin,
  required int port,
  required String pidFile,
  required bool openBrowser,
  void Function(String)? onLine,
}) async {
  final process = await Process.start(flutterBin, [
    'run',
    '-d',
    'web-server',
    '--debug',
    '--web-hostname',
    '127.0.0.1',
    '--web-port',
    '$port',
    '--pid-file',
    pidFile,
  ], workingDirectory: project);
  final tap = LogTap()..add('[oka-dev] flutter run -d web-server');
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((l) {
    tap.add(l);
    onLine?.call(l);
  });
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((l) {
    tap.add(l);
    onLine?.call(l);
  });
  Process? chrome;
  try {
    await tap.waitFor(RegExp(r'is being served at'),
        timeout: const Duration(minutes: 20));
    String? cdpWs;
    if (openBrowser) {
      final (ws, proc) = await _openChrome(port);
      cdpWs = ws;
      chrome = proc;
    }
    final line = await tap.waitFor(RegExp('Dart VM Service'),
        timeout: const Duration(minutes: 25));
    final uri = RegExp(r'http://127\.0\.0\.1:\d+/[\w_-]+=')
        .firstMatch(line)!
        .group(0)!;
    return (_RawApp(process, tap, Uri.parse(uri)), chrome, cdpWs);
  } on Object {
    await tap.close();
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        Process.runSync('pkill', ['-P', '${process.pid}']);
        process.kill(ProcessSignal.sigkill);
        return process.exitCode;
      },
    );
    chrome?.kill();
    rethrow;
  }
}

/// The CLI body, DI-able for tests ([devApp]/[compile]/[targetOverrides]
/// replace the real launch/toolchain; [commands] replaces stdin).
Future<void> runRunDevCli(
  List<String> args, {
  DevApp? devApp,
  UnitDeltaCompiler? compile,
  Map<String, LivePatchTarget> targetOverrides = const {},
  List<ProbeSpec>? probes,
  void Function(String)? output,
  void Function(String)? errorOutput,
  void Function(int)? setExitCode,
  Stream<String>? commands,
  String? workingDir,
}) async {
  final out = output ?? print;
  final err = errorOutput ?? (final m) => stderr.writeln(m);
  final exitWith = setExitCode ?? (final c) => exitCode = c;
  final parsed =
      RunDevArgs.parse(args, cwd: workingDir ?? Directory.current.path);
  if (parsed == null) {
    err(_usage);
    exitWith(2);
    return;
  }
  final isWeb = parsed.platform == 'web';
  final injected = devApp != null;

  // Optional probe spec (gate evidence; the daily loop needs none).
  final specs = probes ?? _loadProbes(parsed.probesFile, err);
  if (specs == null) {
    exitWith(2);
    return;
  }

  String? pidFile;
  String? cdpWs;
  Process? chrome;
  DevApp? app = devApp;
  var reloads = 0;
  String? lastChanged;
  var overrides = Map<String, LivePatchTarget>.of(targetOverrides);

  TargetSpec targetSpec() => isWeb
      ? TargetSpec(
          kind: 'web',
          id: 'app',
          ws: _wsUri(app!.vmUri),
          pidFile: pidFile,
          signal: 'USR1',
          settleMs: 4000,
          cdp: cdpWs,
        )
      : TargetSpec(
          kind: 'vm',
          id: 'app',
          ws: _wsUri(app!.vmUri),
          http: app.vmUri.toString(),
          devfs: 'oka_dev_session',
          applyVia: 'reloadSources',
          packages: '${parsed.project}/.dart_tool/package_config.json',
        );

  LivePatchSpec specFor() => LivePatchSpec(
        revision: 'dev-$reloads',
        unit: parsed.unit,
        patches: const [],
        targets: [targetSpec()],
        probes: specs,
      );

  /// The asset lane (G-RUN): write the changed file into the engine's
  /// asset directory and evict the app's caches. Honesty note: on macOS
  /// the engine serves the previously-mapped bytes until the next engine
  /// cycle (`R`) — the probes verify what is true, and when they have not
  /// flipped the receipt says FAILED with the engine-cache reason rather
  /// than implying the change is live.
  Future<void> syncAssetLane(String changed) async {
    final key = changed.startsWith('${parsed.project}/')
        ? changed.substring('${parsed.project}/'.length)
        : changed;
    final dir = findFlutterAssetsDir(parsed.project);
    if (dir == null) {
      out('assets: no macOS build product found under '
          'build/macos/Build/Products — run the app first; asset '
          'changes need `R` (or a rebuild) otherwise');
      return;
    }
    final bytes = await File(changed).readAsBytes();
    final target = overrides['app'];
    if (target == null) {
      out('assets: no target connected yet');
      return;
    }
    // The delta lane connects through the session; this lane owns the
    // wire directly — connect is idempotent.
    await target.connect();
    final sw = Stopwatch()..start();
    final outcome = await target.syncAsset(
        assetKey: key, bytes: bytes, flutterAssetsDir: dir);
    sw.stop();
    // Probe honesty: capture fingerprints before/after evict so the
    // receipt says whether the change is LIVE (engine cache served the
    // new bytes) or staged-for-next-cycle.
    final probeValues = <String, String>{};
    for (final p in specs) {
      try {
        probeValues[probeKey(p)] = await target.evaluate(p);
      } on Object catch (e) {
        probeValues[probeKey(p)] = 'unreadable ($e)';
      }
    }
    // The header line is the session's greppable spine (gates, humans);
    // --json adds the full receipt object after it.
    out('assets $reloads: ${outcome.ok ? 'OK' : 'FAILED'}');
    out(parsed.jsonOut
        ? const JsonEncoder.withIndent('  ').convert({
            'ok': outcome.ok,
            'mode': outcome.mode,
            'asset': key,
            'bytes': bytes.length,
            'durationMs': sw.elapsedMilliseconds,
            ...outcome.wire,
            'probes': probeValues,
          })
        : 'assets $reloads: ${outcome.ok ? 'OK' : 'FAILED'} — $key '
            '(${bytes.length}B) synced into the engine asset dir, '
            'evict ${outcome.wire['evict'] ?? outcome.error}\n'
            '  probes after evict: '
            '${probeValues.values.join(' | ')}'
            '${outcome.ok ? '' : '\n  FAILED: ${outcome.error}'}');
  }

  Future<void> reload([String? file]) async {
    final raw = file ?? lastChanged;
    if (raw == null) {
      out('reload: no changed file — save one (--watch) or pass it: '
          'r <path>');
      return;
    }
    // Session commands accept project-relative paths; everything
    // downstream (delta compile, asset key, watch set) is absolute.
    final changed = raw.startsWith('/') ? raw : '${parsed.project}/$raw';
    lastChanged = changed;
    reloads++;
    if (!changed.endsWith('.dart')) {
      await syncAssetLane(changed);
      return;
    }
    final receipt = await applyChange(
      specFor(),
      changedFile: changed,
      compile: compile!,
      root: parsed.project,
      targetOverrides: overrides,
    );
    // The header line is the session's greppable spine (gates, humans);
    // --json adds the full receipt object after it.
    out('reload $reloads: ${receipt.ok ? 'OK' : 'FAILED'}');
    out(parsed.jsonOut
        ? const JsonEncoder.withIndent('  ').convert(receipt.toJson())
        : receipt.describe());
  }

  Future<void> restart() async {
    if (app == null) return;
    final sw = Stopwatch()..start();
    app.write('R');
    try {
      await app.waitFor(
        RegExp('Restarted application'),
        timeout: const Duration(minutes: 5),
      );
      if (overrides['app'] case final WebDwdsTarget web) {
        // A web restart reloads the page; the old CDP wire dies with it.
        await web.invalidateCdp();
      }
      out('restart: OK (platform lane, ${sw.elapsedMilliseconds}ms)');
    } catch (e) {
      out('restart: FAILED — $e');
    }
  }

  Future<void> quit() async {
    final a = app;
    if (a == null) return;
    a.write('q');
    await a.stop();
  }

  try {
    if (!injected) {
      final flutterBin = parsed.flutterBin ??
          Platform.environment['FLUTTER_BIN'] ??
          'flutter';
      final device = parsed.device ?? (isWeb ? 'web-server' : 'macos');
      out('dev: launching flutter run -d $device '
          '(${parsed.project.split('/').last})…');

      if (isWeb) {
        pidFile =
            '${Directory.systemTemp.path}/oka-dev-web-${parsed.port}.pid';
        final stale = File(pidFile);
        if (stale.existsSync()) stale.deleteSync();
        final (launched, chromeProc, cdp) = await _launchWeb(
          project: parsed.project,
          flutterBin: flutterBin,
          port: parsed.port,
          pidFile: pidFile,
          openBrowser: parsed.openBrowser,
        );
        app = launched;
        chrome = chromeProc;
        cdpWs = cdp;
        overrides['app'] = WebDwdsTarget(
          id: 'app',
          wsUri: _wsUri(app.vmUri),
          pidFile: pidFile,
          signal: 'USR1',
          cdpPageWsUrl: cdpWs,
        );
        compile = (request) async =>
            // dwds recompiles from source; the delta artifact is advisory.
            DeltaArtifact(path: 'web-advisory.dill', bytes: 0);
      } else {
        final harness = await FlutterRunTarget(
          projectDir: parsed.project,
          device: device,
          flutterBin: flutterBin,
          name: 'oka-dev',
          // First desktop builds of a cold checkout easily exceed the
          // default; the session owns the wait either way.
          vmServiceTimeout: const Duration(minutes: 15),
        ).launch();
        app = _HarnessApp(harness);
        overrides['app'] = VmJitTarget(
          id: 'app',
          wsUri: _wsUri(app.vmUri),
          httpEndpoint: app.vmUri.toString(),
          devfsName: 'oka_dev_session',
          // Desktop embedders die on a failed _reloadKernel — go straight
          // to the reloadSources(rootLibUri) shape flutter's own hot
          // reload uses (ADR-0035 §2e).
          applyVia: 'reloadSources',
          packagesPath: '${parsed.project}/.dart_tool/package_config.json',
        );
        final (dartSdk, frontend, patchedSdk) =
            flutterToolchainPaths(flutterBin);
        compile = flutterFrontendDeltaCompiler(
            frontend, dartSdk, patchedSdk,
            '${parsed.project}/.dart_tool/package_config.json');
      }
      out('dev: VM service at ${app.vmUri}');

      if (parsed.watch) {
        final watcher = LiveWatcher(
          unit: parsed.unit,
          files: _watchSet(parsed.project),
          revision: 'dev-watch',
          targets: [targetSpec()],
          probes: specs,
          compile: compile,
          root: parsed.project,
          targetOverrides: overrides,
        );
        final sub = watcher.receipts.listen((r) {
          out(parsed.jsonOut
              ? const JsonEncoder.withIndent('  ').convert(r.toJson())
              : 'watch: ${r.ok ? 'OK' : 'FAILED'}\n${r.describe()}');
        });
        unawaited(sub.asFuture<void>());
        watcher.start();
      }
    }

    out('dev: ready — commands: r [file] | R | q'
        '${parsed.watch ? ' (--watch on)' : ''}');

    final lineStream = commands ??
        stdin.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lineStream) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed == 'q') break;
      if (trimmed == 'R') {
        await restart();
        continue;
      }
      if (trimmed == 'r' || trimmed.startsWith('r ')) {
        await reload(trimmed.length > 2 ? trimmed.substring(2).trim() : null);
        continue;
      }
      out('unknown command: $trimmed (r [file] | R | q)');
    }
    await quit();
    exitWith(0);
  } catch (e) {
    err('oka run dev: $e');
    await quit();
    exitWith(1);
  } finally {
    chrome?.kill();
    if (pidFile != null) {
      final f = File(pidFile);
      if (f.existsSync()) {
        final pid = int.tryParse(f.readAsStringSync().trim());
        if (pid != null) Process.run('kill', ['$pid']);
        f.deleteSync();
      }
    }
  }
}

String _wsUri(Uri http) =>
    '${http.toString().replaceFirst('http', 'ws').replaceAll(
        RegExp(r'/+$'), '')}/ws';

List<ProbeSpec>? _loadProbes(String? path, void Function(String) err) {
  if (path == null) return const [];
  try {
    final raw = (jsonDecode(File(path).readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    return [for (final p in raw) ProbeSpec.fromJson(p)];
  } catch (e) {
    err('probes spec unreadable: $e');
    return null;
  }
}

/// Every file the watch set covers: the app's dart sources (lib/ plus
/// workspace packages' lib/) plus the declared assets (pubspec
/// `flutter: assets:`, dirs expanded) — the same scan discipline the
/// ship derivation uses. Dart files ride the delta lane; assets ride
/// the sync lane.
List<String> _watchSet(String project) {
  final files = <String>[];
  final packagesDir = Directory('$project/packages');
  final roots = <String>[
    if (Directory('$project/lib').existsSync()) '$project/lib',
    if (packagesDir.existsSync())
      for (final d in packagesDir.listSync()
          .whereType<Directory>()
          .where((d) => Directory('${d.path}/lib').existsSync()))
        '${d.path}/lib',
  ];
  for (final root in roots) {
    files.addAll(Directory(root)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path));
  }
  try {
    files.addAll(declaredAssetFiles(project)
        .map((p) => '$project/$p'));
  } on AssetSpecException {
    // No (or broken) asset declaration: dart-only watch set. The
    // refusal for a hand-named missing asset names the declaration.
  }
  return files;
}

/// Launches Chrome with a fresh profile + CDP pointed at [port]; returns
/// (page-tab WebSocket URL, process) — the tab whose URL serves the app.
Future<(String, Process)> _openChrome(int port) async {
  final profile = Directory.systemTemp.createTempSync('oka-dev-chrome-').path;
  const chromeBin =
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  const cdpPort = 9333;
  final process = await Process.start(chromeBin, [
    '--user-data-dir=$profile',
    '--remote-debugging-port=$cdpPort',
    '--no-first-run',
    '--no-default-browser-check',
    'http://127.0.0.1:$port',
  ]);
  final client = HttpClient();
  for (var attempt = 0; attempt < 40; attempt++) {
    try {
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.1:$cdpPort/json/list'));
      final response = await request.close();
      final tabs = (jsonDecode(
              await response.transform(const Utf8Decoder()).join()) as List)
          .cast<Map<dynamic, dynamic>>();
      for (final t in tabs) {
        if (t['type'] == 'page' &&
            (t['url'] as String? ?? '').contains('127.0.0.1:$port')) {
          return (t['webSocketDebuggerUrl'] as String, process);
        }
      }
    } on Object {
      // Chrome not ready yet.
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError('chrome page for :$port never appeared');
}

Future<void> main(List<String> args) => runRunDevCli(args);
