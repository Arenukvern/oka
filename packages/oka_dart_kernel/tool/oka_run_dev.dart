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
import 'dart:typed_data';

import 'package:flutter_mcp_harness/flutter_mcp_harness.dart';
import 'package:oka_dart_kernel/flutter_attach_session.dart';
import 'package:oka_update/oka_update.dart';

import 'dev_browser_session.dart';
import 'dev_watch_inputs.dart';
import 'flutter_delta.dart';

export 'dev_browser_session.dart';
export 'dev_watch_inputs.dart';

// ignore_for_file: avoid_print

const _usage =
    'usage: oka run dev [--project <dir>] [--platform macos|web]\n'
    '  --device <id>       -d override (default: macos / web-server)\n'
    '  --port <n>          web-server port (default 8187)\n'
    '  --open-browser      web: launch a headless CDP browser by default\n'
    '  --browser-bin <path> explicit browser (otherwise Oka resolution)\n'
    '  --cdp-port <n>      explicit reusable CDP port (default ephemeral)\n'
    '  --browser-headless launch without a window (default)\n'
    '  --browser-visible  explicit visible window; may activate macOS app\n'
    '  --watch-packages project|local|all (default local path dependencies)\n'
    '  --watch             apply every saved file in the watch set\n'
    '                      (default ON, flutter-run parity)\n'
    '  --native-vm-uri URI attach compiler to an externally owned native app; q detaches\n'
    '  --no-watch          explicit loop only (r/R/q)\n'
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
    this.watch = true,
    this.unit = 'dev',
    this.probesFile,
    this.flutterBin,
    this.jsonOut = false,
    this.browserSpec = const BrowserSessionSpec(),
    this.packageWatchScope = DevPackageWatchScope.local,
    this.flutterArgs = const [],
    this.nativeVmUri,
  });

  final String project;
  final String platform;
  final String? device;
  final Uri? nativeVmUri;
  final int port;
  final bool openBrowser;
  final bool watch;
  final String unit;
  final String? probesFile;
  final String? flutterBin;
  final bool jsonOut;
  final BrowserSessionSpec browserSpec;
  final DevPackageWatchScope packageWatchScope;
  final List<String> flutterArgs;

  /// Null when the invocation is malformed; [error] then says why.
  static RunDevArgs? parse(List<String> args, {String? cwd}) {
    String? project = cwd;
    var platform = 'macos';
    String? device;
    Uri? nativeVmUri;
    var port = 8187;
    var openBrowser = false;
    var watch = true;
    var unit = 'dev';
    String? probesFile;
    String? flutterBin;
    var jsonOut = false;
    String? browserBin;
    int? cdpPort;
    var headless = true;
    var watchScope = DevPackageWatchScope.local;
    final flutterArgs = <String>[];
    String? value(String name, String arg, int i) {
      if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
      if (arg == '--$name' && i + 1 < args.length) return args[i + 1];
      return null;
    }

    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--') {
        flutterArgs.addAll(args.skip(i + 1));
        break;
      }
      final nativeUriV = value('native-vm-uri', a, i);
      if (nativeUriV != null) {
        nativeVmUri = Uri.tryParse(nativeUriV);
        if (nativeVmUri == null ||
            !['http', 'https'].contains(nativeVmUri.scheme) ||
            nativeVmUri.host.isEmpty ||
            !nativeVmUri.hasPort ||
            nativeVmUri.port <= 0) {
          return null;
        }
        if (a == '--native-vm-uri') i++;
        continue;
      }
      final browserV = value('browser-bin', a, i);
      if (browserV != null) {
        browserBin = browserV;
        if (a == '--browser-bin') i++;
        continue;
      }
      final cdpV = value('cdp-port', a, i);
      if (cdpV != null) {
        cdpPort = int.tryParse(cdpV);
        if (cdpPort == null || cdpPort <= 0 || cdpPort > 65535) return null;
        if (a == '--cdp-port') i++;
        continue;
      }
      final scopeV = value('watch-packages', a, i);
      if (scopeV != null) {
        final found = DevPackageWatchScope.values.where(
          (s) => s.name == scopeV,
        );
        if (found.isEmpty) return null;
        watchScope = found.single;
        if (a == '--watch-packages') i++;
        continue;
      }
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
        case '--browser-headless':
          headless = true;
        case '--browser-visible':
          headless = false;
        case '--watch':
          watch = true;
        case '--no-watch':
          watch = false;
        case '--json':
          jsonOut = true;
        default:
          return null; // unknown token
      }
    }
    if (project == null ||
        (nativeVmUri != null &&
            (platform != 'macos' || (device != null && device != 'macos')))) {
      return null;
    }
    return RunDevArgs(
      project: project,
      nativeVmUri: nativeVmUri,
      platform: platform,
      device: device,
      port: port,
      openBrowser: openBrowser,
      watch: watch,
      unit: unit,
      probesFile: probesFile,
      flutterBin: flutterBin,
      jsonOut: jsonOut,
      browserSpec: BrowserSessionSpec(
        binaryPath: browserBin,
        debugPort: cdpPort,
        headless: headless,
      ),
      packageWatchScope: watchScope,
      flutterArgs: List.unmodifiable(flutterArgs),
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
  Future<String> waitFor(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 90),
  });

  /// Adapter-owned teardown: stop an owned launch or detach a borrowed app.
  Future<int> stop();
}

/// Live session attachment for consumers. The runner retains ownership;
/// consumers send commands through their supplied stream and observe effects.
class DevSessionAttachment {
  const DevSessionAttachment({
    required this.project,
    required this.app,
    this.browser,
  });
  final String project;
  final DevApp app;
  final DevBrowserSession? browser;
  Uri get vmUri => app.vmUri;
  String? get pageWsUrl => browser?.pageWsUrl;
}

class _AttachedApp implements DevApp {
  _AttachedApp(this.session, this.vmUri);
  final FlutterAttachSession session;
  @override
  final Uri vmUri;
  @override
  void write(String line) => session.write(line);
  @override
  Future<String> waitFor(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 90),
  }) => session.waitFor(pattern, timeout: timeout);
  @override
  Future<int> stop() => session.detach();
}

class _HarnessApp implements DevApp {
  _HarnessApp(this._app);
  final LaunchedApp _app;

  @override
  Uri get vmUri => _app.vmUri;

  @override
  void write(String line) {
    // Published harness exposes Process; borrowed-app variants expose Process?.
    // ignore: unnecessary_nullable_for_final_variable_declarations
    final Process? process = _app.process;
    if (process == null) {
      throw StateError('App has no owned compiler process for input forwarding');
    }
    process.stdin.writeln(line);
  }

  @override
  Future<String> waitFor(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 90),
  }) => _app.stdout.waitFor(pattern, timeout: timeout);

  @override
  Future<int> stop() async {
    await _quitOwnedCompiler(_app.process);
    return _app.stop();
  }
}

Future<void> _quitOwnedCompiler(Process? process) async {
  if (process == null) return;
  process.stdin.writeln('q');
  await process.stdin.flush();
}

class _RawApp implements DevApp {
  _RawApp(this._process, this._tap, this._vmUri);
  final Process _process;
  final LogTap _tap;
  final Uri _vmUri;
  int _commandCursor = 0;

  @override
  Uri get vmUri => _vmUri;

  @override
  void write(String line) {
    _commandCursor = _tap.lineCount;
    _process.stdin.writeln(line);
  }

  @override
  Future<String> waitFor(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    for (final line in _tap.lines.skip(_commandCursor)) {
      if (line.contains(pattern)) return line;
    }
    return _tap.stream
        .firstWhere((line) => line.contains(pattern))
        .timeout(timeout);
  }

  @override
  Future<int> stop() async {
    await _quitOwnedCompiler(_process);
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
Future<(DevApp, DevBrowserSession?)> _launchWeb({
  required String project,
  required String flutterBin,
  required int port,
  required String pidFile,
  required bool openBrowser,
  required BrowserSessionSpec browserSpec,
  required DevBrowserLauncher browserLauncher,
  List<String> extraArgs = const [],
  void Function(String)? onLine,
}) async {
  final process = await Process.start(flutterBin, [
    'run',
    '-d',
    'web-server',
    '--debug',
    '--no-pub',
    ...extraArgs,
    '--web-hostname',
    '127.0.0.1',
    '--web-port',
    '$port',
    '--pid-file',
    pidFile,
  ], workingDirectory: project);
  final tap = LogTap()..add('[oka-dev] flutter run -d web-server');
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (l) {
      tap.add(l);
      onLine?.call(l);
    },
  );
  process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (l) {
      tap.add(l);
      onLine?.call(l);
    },
  );
  DevBrowserSession? browser;
  try {
    await tap.waitFor(
      RegExp(r'is being served at'),
      timeout: const Duration(minutes: 20),
    );
    if (openBrowser) {
      browser = await browserLauncher(
        project: project,
        appUrl: Uri.parse('http://127.0.0.1:$port'),
        spec: browserSpec,
      );
    }
    final line = await tap.waitFor(
      RegExp('Dart VM Service'),
      timeout: const Duration(minutes: 25),
    );
    final uri = RegExp(
      r'http://127\.0\.0\.1:\d+/[\w_-]+=',
    ).firstMatch(line)!.group(0)!;
    return (_RawApp(process, tap, Uri.parse(uri)), browser);
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
    await browser?.stop();
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
  DevBrowserLauncher browserLauncher = launchDevBrowser,
  Future<void> Function(String, String, void Function(String))
      resolveDependencies =
      resolveDevDependencies,
  void Function(DevSessionAttachment)? onSessionReady,
  void Function(String)? onProcessLine,
}) async {
  final out = output ?? print;
  final err = errorOutput ?? (m) => stderr.writeln(m);
  final exitWith = setExitCode ?? (c) => exitCode = c;
  final parsed = RunDevArgs.parse(
    args,
    cwd: workingDir ?? Directory.current.path,
  );
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
  DevBrowserSession? browser;
  DevApp? app = devApp;
  var reloads = 0;
  String? lastChanged;
  var overrides = Map<String, LivePatchTarget>.of(targetOverrides);
  LiveWatcher? watcher;
  StreamSubscription<LivePatchReceipt>? watchSubscription;

  TargetSpec targetSpec() => isWeb
      ? TargetSpec(
          kind: 'web',
          id: 'app',
          ws: _wsUri(app!.vmUri),
          // The injected serving-tool owner acknowledges recompile/apply.
          // A fixed signal-settle delay would add latency without evidence.
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
      out(
        'assets: no macOS build product found under '
        'build/macos/Build/Products — run the app first; asset '
        'changes need `R` (or a rebuild) otherwise',
      );
      return;
    }
    var bytes = await File(changed).readAsBytes();
    Uint8List payload;
    var isShader = false;
    if (changed.endsWith('.frag')) {
      // Fragment shaders are NOT bundle assets: compile the source with
      // impellerc (the build's own toolchain) — the compiled bytes ride
      // the bundle under the SOURCE's key.
      isShader = true;
      try {
        payload = await compileShader(
          fragPath: changed,
          flutterBin: _flutterBinFor(parsed),
        );
      } on AssetSpecException catch (e) {
        out('assets: ${e.message}');
        return;
      }
    } else {
      payload = bytes;
    }
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
      assetKey: key,
      bytes: payload,
      flutterAssetsDir: dir,
      shader: isShader,
    );
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
    out(
      parsed.jsonOut
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
                '${outcome.ok ? '' : '\n  FAILED: ${outcome.error}'}',
    );
  }

  Future<void> reload([String? file]) async {
    final raw = file ?? lastChanged;
    if (raw == null) {
      out(
        'reload: no changed file — save one (--watch) or pass it: '
        'r <path>',
      );
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
    out(
      parsed.jsonOut
          ? const JsonEncoder.withIndent('  ').convert(receipt.toJson())
          : receipt.describe(),
    );
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
      onSessionReady?.call(
        DevSessionAttachment(
          project: parsed.project,
          app: app!,
          browser: browser,
        ),
      );
    } catch (e) {
      out('restart: FAILED — $e');
    }
  }

  Future<void>? quitting;
  Future<void> quit() => quitting ??= () async {
    final a = app;
    if (a != null) await a.stop();
    out('dev: session adapter stopped');
  }();

  try {
    if (!injected) {
      final flutterBin =
          parsed.flutterBin ?? Platform.environment['FLUTTER_BIN'] ?? 'flutter';
      final device = parsed.device ?? (isWeb ? 'web-server' : 'macos');
      final operation = parsed.nativeVmUri == null
          ? 'launching flutter run'
          : 'attaching Flutter compiler';
      out(
        'dev: $operation -d $device '
        '(${parsed.project.split('/').last})…',
      );

      // Deterministic bring-up: pub is resolved ONCE, offline, before
      // launch — `flutter run`'s implicit resolve hangs indefinitely on
      // an unstable network (measured), and --no-pub turns that class
      // of stall into a fast, named failure.
      await resolveDependencies(parsed.project, flutterBin, out);
      final nativeVmUri = parsed.nativeVmUri;
      if (isWeb) {
        pidFile =
            '${Directory.systemTemp.path}/oka-dev-web-${parsed.port}-${DateTime.now().microsecondsSinceEpoch}.pid';
        final stale = File(pidFile);
        if (stale.existsSync()) stale.deleteSync();
        final (launched, launchedBrowser) = await _launchWeb(
          project: parsed.project,
          flutterBin: flutterBin,
          port: parsed.port,
          pidFile: pidFile,
          openBrowser: parsed.openBrowser,
          browserSpec: parsed.browserSpec,
          browserLauncher: browserLauncher,
          extraArgs: parsed.flutterArgs,
          onLine: onProcessLine,
        );
        app = launched;
        browser = launchedBrowser;
        cdpWs = browser?.pageWsUrl;
        overrides['app'] = WebDwdsTarget(
          id: 'app',
          wsUri: _wsUri(app.vmUri),
          pidFile: pidFile,
          cdpPageWsUrl: cdpWs,
          platformReload: () async {
            app!.write('r');
            final acknowledgement = await app.waitFor(
              RegExp(
                'Reloaded application|Hot reload failed|Try again after fixing',
              ),
              timeout: const Duration(seconds: 90),
            );
            if (!acknowledgement.contains('Reloaded application')) {
              throw LiveWireException(
                'Platform reload refused: $acknowledgement',
              );
            }
          },
        );
        compile = (request) async =>
            // dwds recompiles from source; the delta artifact is advisory.
            DeltaArtifact(path: 'web-advisory.dill', bytes: 0);
      } else if (nativeVmUri != null) {
        final session = await FlutterAttachSession.start(
          project: parsed.project,
          flutterBin: flutterBin,
          vmUri: nativeVmUri,
          extraArgs: parsed.flutterArgs,
          onLine: onProcessLine,
        );
        app = _AttachedApp(session, nativeVmUri);
        overrides['app'] = VmJitTarget(
          id: 'app',
          wsUri: _wsUri(app.vmUri),
          platformReload: () async {
            app!.write('r');
            final acknowledgement = await app.waitFor(
              RegExp(
                'Reloaded [0-9]+ of|Hot reload failed|Try again after fixing',
              ),
            );
            if (!acknowledgement.startsWith('Reloaded ')) {
              throw LiveWireException(
                'Native reload owner refused: $acknowledgement',
              );
            }
          },
        );
        compile = (_) async =>
            const DeltaArtifact(path: 'native-serving-advisory.dill', bytes: 0);
      } else {
        final harness = await FlutterRunTarget(
          projectDir: parsed.project,
          device: device,
          extraArgs: ['--no-pub', ...parsed.flutterArgs],
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
        final (dartSdk, frontend, patchedSdk) = flutterToolchainPaths(
          flutterBin,
        );
        compile = flutterFrontendDeltaCompiler(
          frontend,
          dartSdk,
          patchedSdk,
          '${parsed.project}/.dart_tool/package_config.json',
        );
      }
      out('dev: VM service at ${app.vmUri}');

      if (parsed.watch) {
        watcher = LiveWatcher(
          unit: parsed.unit,
          files: resolveDevWatchFiles(
            parsed.project,
            packageScope: parsed.packageWatchScope,
          ),
          revision: 'dev-watch',
          targets: [targetSpec()],
          probes: specs,
          compile: compile,
          root: parsed.project,
          targetOverrides: overrides,
        );
        watchSubscription = watcher.receipts.listen((r) {
          out(
            parsed.jsonOut
                ? const JsonEncoder.withIndent('  ').convert(r.toJson())
                : 'watch: ${r.ok ? 'OK' : 'FAILED'}\n${r.describe()}',
          );
        });
        watcher.start();
      }
    }

    onSessionReady?.call(
      DevSessionAttachment(
        project: parsed.project,
        app: app!,
        browser: browser,
      ),
    );
    out(
      'dev: ready — commands: r [file] | R | q'
      '${parsed.watch ? ' (--watch on)' : ''}',
    );

    final lineStream =
        commands ??
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
    await watcher?.stop();
    await watchSubscription?.cancel();
    for (final entry in overrides.entries) {
      // Injected target wires remain with their caller; close only ours.
      if (!identical(targetOverrides[entry.key], entry.value)) {
        await entry.value.close();
      }
    }
    await browser?.stop();
    if (pidFile != null) {
      final f = File(pidFile);
      if (f.existsSync()) {
        f.deleteSync();
      }
    }
    out('dev: session closed');
  }
}

/// One offline resolution before launch: fast, deterministic, and the
/// failure (a genuinely missing package, or a lock held by a zombie
/// flutter command) is named instead of a silent multi-minute hang
/// inside `flutter run`'s implicit resolve. The lock-wait line is
/// surfaced live — "Waiting for another flutter command…" is the stall
/// users otherwise only see in a swallowed log.
Future<void> resolveDevDependencies(
  String project,
  String flutterBin,
  void Function(String) out,
) async {
  final sw = Stopwatch()..start();
  out('dev: pub get --offline…');
  final process = await Process.start(flutterBin, [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: project);
  final stdoutLog = StringBuffer();
  final stderrLog = StringBuffer();
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (l) {
          stdoutLog.writeln(l);
          if (l.contains('Waiting for another flutter command')) {
            out(
              'dev: pub get --offline: $l (another session holds the SDK '
              'lock — preserve its owner and wait or select an independent SDK)',
            );
          }
        },
        onDone: stdoutDone.complete,
        onError: stdoutDone.completeError,
      );
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        stderrLog.writeln,
        onDone: stderrDone.complete,
        onError: stderrDone.completeError,
      );
  final code = await process.exitCode.timeout(
    const Duration(minutes: 3),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      throw StateError(
        'flutter pub get --offline exceeded 3 minutes; inspect the SDK '
        'or dependency-resolution owner and preserve unrelated sessions',
      );
    },
  );
  // Register stream completion at listen time. asFuture after process exit can
  // attach after onDone already ran and wait forever for a closed stream.
  await Future.wait([stdoutDone.future, stderrDone.future]);
  sw.stop();
  if (code != 0) {
    throw StateError(
      'flutter pub get --offline failed (${sw.elapsedMilliseconds}ms):\n'
      '$stdoutLog\n$stderrLog',
    );
  }
  out('dev: pub get --offline ok (${sw.elapsedMilliseconds}ms)');
}

/// The flutter binary for toolchain lookups: explicit flag, env, PATH,
/// then the fvm default checkout (the same discovery oka ship uses).
String _flutterBinFor(RunDevArgs parsed) {
  final env = Platform.environment['FLUTTER_BIN'];
  if (parsed.flutterBin != null) return parsed.flutterBin!;
  if (env != null) return env;
  final which = Process.runSync('which', ['flutter']);
  if (which.exitCode == 0) return (which.stdout as String).trim();
  final fvm = '${Platform.environment['HOME']}/fvm/default/bin/flutter';
  if (File(fvm).existsSync()) return fvm;
  return 'flutter';
}

String _wsUri(Uri http) =>
    '${http.toString().replaceFirst('http', 'ws').replaceAll(RegExp(r'/+$'), '')}/ws';

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

Future<void> main(List<String> args) => runRunDevCli(args);
