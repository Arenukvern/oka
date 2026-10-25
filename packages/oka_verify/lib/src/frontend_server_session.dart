/// Resident frontend-server session for the oka verify lane (ADR-0048).
///
/// Drives the SDK's own incremental compiler frontend over its stdio
/// protocol — the same contract flutter_tools' `DefaultResidentCompiler`
/// speaks, mirrored line-for-line so the two clients stay interchangeable:
///
///   -> `compile <entry>`            full compile of a new program
///   -> `recompile <entry> <key>`    delta compile, invalidated paths
///                                    followed by the echoed key
///   -> `accept` / `reject`          commit or roll back the last result
///   <- `result <key>`               boundary key for this request
///   <- diagnostics                  compile messages
///   <- `<key>`                      separator
///   <- `+<uri>` / `-<uri>`          added/removed sources
///   <- `<key> <dill> <errorCount>`  final line for the request
///
/// One process serves many sequential `compile` requests (a new program
/// each time) while keeping the front-end warm: no per-compile dartdev or
/// native-assets boot, which is what a per-suite `dart compile kernel`
/// pool pays for every suite.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The result of one compile request.
final class CompileResult {
  CompileResult({
    required this.dillPath,
    required this.errorCount,
    required this.diagnostics,
  });

  /// The dill the front end wrote.
  final String dillPath;

  /// The number of compile errors; zero means success.
  final int errorCount;

  /// The compiler's messages for this request.
  final String diagnostics;

  /// True when the compile succeeded.
  bool get ok => errorCount == 0;
}

/// A failure of the front-end session itself (not of the compiled program).
final class FrontendServerException implements Exception {
  FrontendServerException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'FrontendServerException: $message';
}

/// The parsed state machine for one request's stdout. Mirrors
/// flutter_tools' `StdoutHandler`; extracted as a pure class so tests can
/// feed captured transcript lines.
final class FrontendServerParser {
  String? _boundaryKey;
  final StringBuffer _diagnostics = StringBuffer();

  /// Completes with the final `<key> <dill> <errorCount>` line.
  final Completer<CompileResult> output = Completer<CompileResult>();

  /// Feeds one stdout line to the parser.
  void handle(String message) {
    const resultPrefix = 'result ';
    final key = _boundaryKey;
    if (key == null && message.startsWith(resultPrefix)) {
      _boundaryKey = message.substring(resultPrefix.length);
      return;
    }
    if (key != null && message.startsWith(key)) {
      if (message.length <= key.length) return; // separator line
      final space = message.lastIndexOf(' ');
      output.complete(
        CompileResult(
          dillPath: message.substring(key.length + 1, space),
          errorCount: int.parse(message.substring(space + 1).trim()),
          diagnostics: _diagnostics.toString(),
        ),
      );
      return;
    }
    if (key != null) _diagnostics.writeln(message);
    // Lines outside a request (`accepted`, notices) are ignored.
  }
}

/// One warm front end serving many suite compiles.
final class FrontendServerSession {
  FrontendServerSession._(this._process, this._scratchDill) {
    unawaited(_pump());
    unawaited(_process.exitCode.then((_) => _dead = true));
  }

  final Process _process;
  final String _scratchDill;
  FrontendServerParser? _current;
  final _lock = _AsyncLock();
  bool _dead = false;
  bool _lastFailed = false;

  /// The path the server currently writes its full dill to. It is copied to
  /// a per-suite destination after a successful compile, because the server
  /// deletes its output when it processes the accept.
  String get scratchDill => _scratchDill;

  /// False once the server process is gone.
  bool get isAlive => !_dead;

  /// Starts one warm frontend server writing full dills to [scratchDill].
  static Future<FrontendServerSession> start({
    required String sdkRoot,
    required String scratchDill,
    String? packagesPath,
    bool enableAsserts = true,
  }) async {
    final bin = Directory(sdkRoot).resolveSymbolicLinksSync();
    final runtime = '$bin/bin/dartaotruntime';
    final snapshot = '$bin/bin/snapshots/frontend_server_aot.dart.snapshot';
    if (!File(runtime).existsSync() || !File(snapshot).existsSync()) {
      throw FrontendServerException('frontend server missing under $bin');
    }
    final process = await Process.start(runtime, [
      snapshot,
      '--sdk-root',
      '$bin/',
      '--platform',
      '$bin/lib/_internal/vm_platform_strong.dill',
      '--incremental',
      '--target=vm',
      if (enableAsserts) '--enable-asserts',
      if (packagesPath != null) ...['--packages', packagesPath],
      '--output-dill',
      scratchDill,
      '--verbosity=error',
    ]);
    return FrontendServerSession._(process, scratchDill);
  }

  /// Full compile of a new program ([entryPath]: file path or `package:`
  /// URI). One program per compile; sequential only. [copyTo] snapshots
  /// the freshly written dill BEFORE `accept` — the server deletes its
  /// output when it processes the accept, so callers that want to keep
  /// per-compile artifacts must snapshot inside this window.
  Future<CompileResult> compile(String entryPath, {String? copyTo}) =>
      _send('compile $entryPath', copyTo: copyTo);

  /// Delta compile after [invalidatedPaths] changed.
  Future<CompileResult> recompile(
    String entryPath,
    Iterable<String> invalidatedPaths,
  ) {
    final key = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return _send(
      ['recompile $entryPath $key', ...invalidatedPaths, key].join('\n'),
    );
  }

  Future<CompileResult> _send(String command, {String? copyTo}) =>
      _lock.synchronized(() async {
        if (_dead) {
          throw FrontendServerException('frontend server exited');
        }
        if (_lastFailed) {
          // A failed request leaves the server on the rejected program;
          // roll it back before the next compile. The rollback's own
          // output lines arrive while no parser is current and are
          // ignored by the pump.
          _process.stdin.writeln('reject');
        }
        _lastFailed = false;
        final parser = FrontendServerParser();
        _current = parser;
        _process.stdin.writeln(command);
        final result = await parser.output.future.timeout(
          const Duration(minutes: 10),
          onTimeout: () {
            _dead = true;
            _process.kill();
            throw FrontendServerException('compile timed out: $command');
          },
        );
        _current = null;
        if (result.ok) {
          if (copyTo != null) {
            try {
              await File(result.dillPath).copy(copyTo);
            } on FileSystemException catch (e) {
              // The server reported ok but its artifact is not on disk.
              // Surface as a session failure so callers can fall back.
              throw FrontendServerException(
                'front end wrote no dill at ${result.dillPath}: ${e.message}',
              );
            }
          }
          _process.stdin.writeln('accept');
        } else {
          _lastFailed = true;
        }
        return result;
      });

  /// Dispatches every stdout line to whichever request is open. The
  /// `accepted` acknowledgment lands between requests and is ignored.
  Future<void> _pump() async {
    final lines = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line == 'accepted') continue;
      _current?.handle(line);
    }
    _current?.output.completeError(
      FrontendServerException('frontend server exited mid-compile'),
      StackTrace.current,
    );
    _current = null;
  }

  /// Stops the server and removes its scratch dill.
  Future<void> quit() async {
    _process.stdin.writeln('quit');
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
    // The scratch dill is ours alone (unique per session) — the server
    // deletes a pre-existing output path at startup, so reusing one name
    // across sessions races its own cleanup.
    final scratch = File(_scratchDill);
    if (scratch.existsSync()) scratch.deleteSync();
  }
}

class _AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> synchronized<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
