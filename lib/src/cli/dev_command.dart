import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_android/oka_android.dart';

/// `oka dev` — build + install + launch + attach session (ADR-0011).
///
/// One of the three device-flow surfaces:
///
/// * `oka run device` (= `oka launch`): one-shot install + launch +
///   failure-signature scan. No session.
/// * `oka dev`: build validated against the session manifest (H1), the
///   device steps (install → launch → logscan via the same DeviceTarget
///   machinery), VM-service reachability (H2 artifacts), then a
///   `flutter attach --machine` session (H3) with hot reload/restart.
///
/// This file stays parse-and-delegate (ADR-0015: verbs never know
/// platforms): every bit of session logic lives in oka_android's dev
/// layer ([checkDevSession], [selectDevDevice], [prepareDevLaunch],
/// [DevSession], [DevFlow], [watchCommandStream]). The keyboard loop here
/// is the one explicit interactive surface (never a build path).
class DevCommand {
  Future<void> run(final List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'device',
        abbr: 'd',
        help:
            'Target device ID (required '
            'when zero or multiple devices are attached)',
      )
      ..addOption(
        'target',
        help:
            'Flutter entrypoint to request (validated against the '
            'recorded session manifest)',
      )
      ..addMultiOption(
        'dart-define',
        help:
            'Additional KEY=VALUE dart-define (validated against the '
            'recorded session manifest)',
      )
      ..addOption(
        'dart-define-from-file',
        help:
            'JSON file with KEY: VALUE defines (validated against the '
            'recorded session manifest)',
      )
      ..addFlag(
        'json',
        negatable: false,
        help:
            'Agent stream: structured events on stdout; control lines '
            'on stdin (reload/restart/stop/detach/quit)',
      )
      ..addFlag(
        'watch',
        negatable: false,
        help:
            'Watch Dart changes → hot reload; native/res/manifest '
            'changes → honest full-rebuild routing (no keyboard)',
      )
      ..addFlag(
        'rebuild-on-native',
        negatable: false,
        help:
            'With --watch: automatically rebuild + reinstall + relaunch '
            '+ re-attach on native changes',
      )
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Verbose output')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');

    final results = parser.parse(args);
    if (results['help'] as bool) {
      _printUsage(parser);
      return;
    }
    if (results['rebuild-on-native'] as bool && !(results['watch'] as bool)) {
      stderr.writeln(
        '❌ --rebuild-on-native requires --watch (it only affects the '
        'watch loop).',
      );
      exit(2);
    }
    final json = results['json'] as bool;
    final watch = results['watch'] as bool;
    final verbose = results['verbose'] as bool;

    print('🚀 Oka Development Mode\n');

    // H1 preflight: manifest validation + recorded-SDK binary resolution.
    final projectPath = Directory.current.path;
    final check = await checkDevSession(
      projectPath: projectPath,
      targetFile: (results['target'] as String?)?.trim(),
      dartDefinePairs: results['dart-define'] as List<String>,
      dartDefineFromFile: results['dart-define-from-file'] as String?,
    );
    check.lines.forEach(print);
    if (!check.ok) {
      stderr.writeln(check.refusal);
      exit(1);
    }
    final session = check.session!;
    final flutterBinary = flutterBinaryForSdk(session.flutterSdkPath).path;
    print('');
    print('✅ Session manifest validated — attaching from the recorded SDK.');
    print('');

    // Device selection (zero/multiple devices → errors over the device
    // layer; failures classified with oka-style fixes). The resolved
    // tool binary path is also prepended to the attach child's PATH —
    // the flutter tool discovers devices through it, and the oka-managed
    // SDK dir is often not on the ambient PATH.
    final devToolchain = ResolvedToolchain();
    final tools = await resolveDevToolPath(devToolchain);
    if (tools.path == null) {
      stderr.writeln(tools.refusal);
      exit(1);
    }
    final devToolPath = tools.path!;
    final selection = await selectDevDevice(
      deviceId: results['device'] as String?,
      adbPath: devToolPath,
      toolchain: devToolchain,
    );
    if (!selection.ok || selection.device == null) {
      stderr.writeln(selection.refusal);
      exit(1);
    }
    final deviceId = selection.device!.id;

    // One control-command source shared by keyboard / stdin / watcher.
    final control = StreamController<DevControlCommand>.broadcast();

    final flow = DevFlow(
      // Device half (install/launch/logscan via the DeviceTarget steps +
      // VM-service steps) then spawn the attach daemon from the recorded
      // SDK binary.
      prepare: () async {
        // Device half first (install/launch/logscan + VM-service steps);
        // a failure throws DevLaunchException, handled by DevFlow.
        await prepareDevLaunch(
          projectPath: projectPath,
          deviceId: deviceId,
          adbPath: devToolPath,
          verbose: verbose,
        );
        final adapter = FlutterDaemonAdapter(
          transport: await spawnAttachDaemon(
            flutterBinary: flutterBinary,
            deviceId: deviceId,
            adbPath: devToolPath,
          ),
          verbose: verbose,
        );
        return DevSession(
          adapter: adapter,
          session: session,
          deviceId: deviceId,
          json: json,
          write: print,
          commands: control.stream,
          verbose: verbose,
          rebuildOnNative: results['rebuild-on-native'] as bool,
        );
      },
      // Full rebuild on native changes (with the exact parity flags the
      // session was validated against), then re-attach (build → install →
      // relaunch → re-attach).
      runBuild: () => _rebuild(projectPath, results: results, session: session),
    );

    _wireInput(
      control,
      json: json,
      watch: watch,
      projectPath: projectPath,
      targetFile: (results['target'] as String?)?.trim(),
      verbose: verbose,
    );

    exit(await flow.run());
  }

  /// The full rebuild for `--rebuild-on-native`: delegates to the project
  /// entrypoint exactly like `oka build apk --debug` does (ADR-0006/0010),
  /// forwarding the session-parity flags. Install/relaunch/re-attach
  /// happen in the next [DevFlow] prepare round.
  Future<bool> _rebuild(
    final String projectPath, {
    required final ArgResults results,
    required final RunSession session,
  }) async {
    final entrypoint = await findPipelineEntrypoint(projectPath);
    if (entrypoint == null) {
      stderr.writeln(
        '❌ No project entrypoint (tool/oka_pipeline.dart) — cannot '
        'rebuild. Run `oka build apk --debug` manually, then re-run '
        '`oka dev`.',
      );
      return false;
    }
    print('🔨 Native change → full rebuild (`oka build apk --debug`)…');
    final argv = [
      'run',
      entrypoint,
      '--platform',
      'android',
      if ((results['target'] as String?)?.trim().isNotEmpty ?? false) ...[
        '--target',
        results['target'] as String,
      ],
      for (final d in results['dart-define'] as List<String>) ...[
        '--dart-define',
        d,
      ],
      if ((results['dart-define-from-file'] as String?)?.isNotEmpty ??
          false) ...[
        '--dart-define-from-file',
        results['dart-define-from-file'] as String,
      ],
    ];
    final proc = await Process.start(
      'dart',
      argv,
      workingDirectory: projectPath,
      mode: ProcessStartMode.inheritStdio,
      runInShell: true,
    );
    return await proc.exitCode == 0;
  }

  /// Wires the control surface for this invocation:
  ///
  /// * human TTY: `r` reload, `R` hot restart, `q` quit, `d` detach
  ///   (single keystrokes, echo off — oka renders, never the flutter TUI);
  /// * `--json`: one control line per command on stdin
  ///   (reload/restart/stop/detach/quit);
  /// * `--watch`: file watching → classification → commands (no keyboard).
  void _wireInput(
    final StreamController<DevControlCommand> control, {
    required final bool json,
    required final bool watch,
    required final String projectPath,
    required final String? targetFile,
    required final bool verbose,
  }) {
    if (watch) {
      final changes = watchDevPaths(
        projectPath: projectPath,
        targetFile: targetFile,
      );
      watchCommandStream(
        changes: changes,
        onEvent: (final c) {
          if (verbose || json) {
            print('👀 Watch: ${c.reasons.join('; ')}');
          }
        },
      ).listen(
        control.add,
        onError: (final Object e) => stderr.writeln('❌ Watcher error: $e'),
      );
    }

    // The keyboard/line loop is the one explicit interactive surface of
    // `oka dev` — never present in watch mode (non-TTY-safe), and never in
    // build paths.
    if (watch) return;
    if (json) {
      stdin
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (final line) => control.add(_fromLine(line, onUnknown: _jsonUsage)),
          );
      return;
    }
    if (stdin.hasTerminal) {
      stdin.echoMode = false;
      stdin.lineMode = false;
      final buffer = <int>[];
      stdin.listen((final bytes) {
        buffer.addAll(bytes);
        while (buffer.isNotEmpty) {
          final byte = buffer.removeAt(0);
          final c = devCommandFromKey(String.fromCharCode(byte));
          if (c != null) control.add(c);
        }
      });
    }
  }

  DevControlCommand _fromLine(
    final String line, {
    required final void Function() onUnknown,
  }) {
    final c = devCommandFromLine(line);
    if (c == null) onUnknown();
    return c ?? DevControlCommand.reload;
  }

  void _jsonUsage() {
    stderr.writeln(
      '{"scope":"dev","event":"usage","params":{"commands":'
      '["reload","restart","stop","detach","quit"]}}',
    );
  }
}

void _printUsage(final ArgParser parser) {
  print(
    'oka dev — build + install + launch + hot-reload attach session '
    '(ADR-0011)\n',
  );
  print('Usage: oka dev [options]\n');
  print(parser.usage);
  print('''
The three device-flow surfaces:
  oka run device (alias: oka launch)  one-shot install + launch +
                                      failure-signature scan. No session.
  oka dev                             build-parity check + install +
                                      launch + attach session (below).

Session controls (human TTY): r hot reload · R hot restart (loses app
state — a full kernel recompile + restart) · q quit (stops the app) ·
d detach (keeps the app running).
Agent stream (--json): structured events on stdout; control lines on
stdin: reload / restart / stop / detach / quit.

The session manifest (run_session.json, recorded by `oka build apk
--debug`) is validated against the requested flags; a mismatch refuses
with the exact differing fields — a mismatched attach would corrupt the
running app at runtime instead of failing here. The session flutter
binary always comes from the SDK path recorded in the manifest, never
PATH. Hot reload is Dart-only: native/res/manifest changes need
`oka build apk --debug` + reinstall (see --watch --rebuild-on-native).
''');
}
