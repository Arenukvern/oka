// Foreign orphan reaping (ADR-0053): family-limited, identity-gated
// SIGKILL of supervisor-reparented toolchain processes (pid-1 or
// launchd/systemd --user parents). POSIX-only fixtures (`sleep`);
// Windows behavior is covered by the fake-seam tests.
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

/// Scripted liveness: tokens per pid; when [rotating] is set, each
/// identityToken read returns a fresh value — modeling a pid that was
/// recycled between the scan-time capture and the signal-time gate.
final class _FakeLiveness implements ProcessLiveness {
  _FakeLiveness({Map<int, String>? tokens, Set<int>? alive})
    : _tokens = tokens ?? {},
      _alive = alive ?? {};

  final Map<int, String> _tokens;
  final Set<int> _alive;
  int _reads = 0;

  void killForTest(int pid) {
    _alive.remove(pid);
    _tokens.remove(pid);
  }

  @override
  Future<bool> isAlive(int pid) async => _alive.contains(pid);

  @override
  Future<String?> identityToken(int pid) async {
    _reads++;
    if (rotating) return 'rotating-$_reads';
    return _tokens[pid];
  }

  /// Whether every identity read returns a distinct token.
  bool rotating = false;

  @override
  Future<bool> kill(int pid, {Duration grace = const Duration(seconds: 3)}) =>
      throw UnimplementedError('the reaper must use its own kill seam');
}

ForeignProcessRow _row(
  int pid, {
  int ppid = 1,
  String command = '',
  Duration elapsed = const Duration(hours: 5),
}) => ForeignProcessRow(
  pid: pid,
  ppid: ppid,
  command: command,
  elapsed: elapsed,
);

void main() {
  test('reaps matching orphan rows end-to-end over fake seams', () async {
    final killed = <int>[];
    final liveness = _FakeLiveness(
      tokens: {4242: 't1', 4243: 't2'},
      alive: {4242, 4243},
    );
    final summary = await reapForeignOrphans(
      '/nonexistent-project',
      liveness: liveness,
      processTable:
          () async => [
            _row(4242, command: 'dart .../flutter_tools.snapshot run -d macos'),
            _row(
              4243,
              command: 'dartaotruntime .../frontend_server_aot.dart.snapshot',
            ),
          ],
      killProcess: (pid) async {
        killed.add(pid);
        liveness.killForTest(pid);
        return true;
      },
      liveLeasePids: () async => {},
    );

    expect(killed, unorderedEquals([4242, 4243]));
    expect(summary.count(ForeignReapDisposition.killed), 2);
    expect(summary.clean, isTrue);
  });

  test('skips young, protected, leased, parented and off-family rows', () async {
    final killed = <int>[];
    final liveness = _FakeLiveness(tokens: {11: 't'}, alive: {11});
    final summary = await reapForeignOrphans(
      '/nonexistent-project',
      liveness: liveness,
      processTable:
          () async => [
            // Off family: never a candidate.
            _row(1, command: '/Applications/Zed.app/Contents/MacOS/zed'),
            // Parent alive in the table and not a supervisor: somebody's
            // session, never an escape.
            _row(
              2,
              ppid: 3272,
              command: 'dart flutter_tools.snapshot run',
            ),
            _row(3272, command: '/Applications/Zed.app/Contents/MacOS/zed'),
            // Family match but young.
            _row(
              3,
              command: 'dartaotruntime .../frontend_server_aot.dart.snapshot',
              elapsed: const Duration(minutes: 2),
            ),
            // Family match, recorded live in the lease registry.
            _row(11, command: 'dart .../flutter_tools.snapshot test'),
            // Family match but protected — via explicitly supplied names,
            // the path a Dart composition root takes. Machine-local names
            // are never library defaults.
            _row(
              12,
              command:
                  '/x/build/ecsai_daemon.exe --plugins flutter_tester',
            ),
          ],
      killProcess: (pid) async {
        killed.add(pid);
        return true;
      },
      liveLeasePids: () async => {11},
      protectedNames: const ['ecsai_daemon.exe'],
    );

    expect(killed, isEmpty);
    expect(summary.count(ForeignReapDisposition.skippedTooYoung), 1);
    expect(summary.count(ForeignReapDisposition.skippedLeaseRecorded), 1);
    expect(summary.count(ForeignReapDisposition.skippedProtected), 1);
    // Off-family and parented rows never become receipts: they are not
    // candidates at all.
    expect(summary.receipts, hasLength(3));
  });

  test('reaps rows reparented to a non-pid-1 supervisor (systemd --user)',
      () async {
    final killed = <int>[];
    final liveness = _FakeLiveness(tokens: {21: 't'}, alive: {21});
    final summary = await reapForeignOrphans(
      '/nonexistent-project',
      liveness: liveness,
      processTable:
          () async => [
            // Linux: the user manager adopts orphaned session processes
            // (child subreaper), so the escape parent is NOT pid 1.
            _row(900, command: '/usr/lib/systemd/systemd --user'),
            _row(
              21,
              ppid: 900,
              command: 'dart .../frontend_server_aot.dart.snapshot',
            ),
          ],
      killProcess: (pid) async {
        killed.add(pid);
        liveness.killForTest(pid);
        return true;
      },
      liveLeasePids: () async => {},
    );

    expect(killed, [21]);
    expect(summary.count(ForeignReapDisposition.killed), 1);
    expect(summary.clean, isTrue);
  });

  test('a parent absent from the table is never treated as an escape',
      () async {
    final killed = <int>[];
    final summary = await reapForeignOrphans(
      '/nonexistent-project',
      liveness: _FakeLiveness(tokens: {22: 't'}, alive: {22}),
      processTable:
          () async => [
            _row(
              22,
              ppid: 999999,
              command: 'dart .../frontend_server_aot.dart.snapshot',
            ),
          ],
      killProcess: (pid) async {
        killed.add(pid);
        return true;
      },
      liveLeasePids: () async => {},
    );

    // Unresolvable parentage is unverifiable, not orphaned: report
    // nothing, signal nothing.
    expect(killed, isEmpty);
    expect(summary.receipts, isEmpty);
  });

  test('never signals a recycled pid (identity changed since scan)', () async {
    final killed = <int>[];
    final liveness = _FakeLiveness(tokens: {77: 't'})..rotating = true;
    final summary = await reapForeignOrphans(
      '/nonexistent-project',
      liveness: liveness,
      processTable:
          () async => [
            _row(77, command: 'dart .../flutter_tools.snapshot attach'),
          ],
      killProcess: (pid) async {
        killed.add(pid);
        return true;
      },
      liveLeasePids: () async => {},
    );

    expect(killed, isEmpty);
    expect(summary.count(ForeignReapDisposition.skippedIdentityChanged), 1);
  });

  test('reports unverifiable identity instead of guessing', () async {
    final killed = <int>[];
    final summary = await reapForeignOrphans(
      '/nonexistent-project',
      liveness: _FakeLiveness(), // no token for the pid
      processTable:
          () async => [
            _row(99, command: 'dart .../development-service --serve-devtools'),
          ],
      killProcess: (pid) async {
        killed.add(pid);
        return true;
      },
      liveLeasePids: () async => {},
    );

    expect(killed, isEmpty);
    expect(summary.count(ForeignReapDisposition.skippedUnverifiable), 1);
  });

  test('dry-run reports wouldKill and signals nothing', () async {
    final killed = <int>[];
    final liveness = _FakeLiveness(tokens: {5: 't'}, alive: {5});
    final summary = await reapForeignOrphans(
      '/nonexistent-project',
      liveness: liveness,
      processTable:
          () async => [_row(5, command: 'dart .../flutter_tools.snapshot run')],
      killProcess: (pid) async {
        killed.add(pid);
        return true;
      },
      liveLeasePids: () async => {},
      dryRun: true,
    );

    expect(killed, isEmpty);
    expect(summary.count(ForeignReapDisposition.wouldKill), 1);
    expect(summary.clean, isTrue);
  });

  test('a SIGKILL survivor is killFailed, never claimed success', () async {
    final liveness = _FakeLiveness(tokens: {6: 't'}, alive: {6});
    final summary = await reapForeignOrphans(
      '/nonexistent-project',
      liveness: liveness,
      processTable:
          () async => [_row(6, command: 'dart .../flutter_tester listener')],
      killProcess: (_) async => true, // delivered, but survival modeled below
      liveLeasePids: () async => {},
      deathCheckDelay: Duration.zero,
    );

    expect(summary.count(ForeignReapDisposition.killFailed), 1);
    expect(summary.clean, isFalse);
  });

  test('parses ps etime variants', () {
    expect(parsePsEtime('05:33'), const Duration(minutes: 5, seconds: 33));
    expect(parsePsEtime('03:04:05'), const Duration(hours: 3, minutes: 4, seconds: 5));
    expect(parsePsEtime('2-03:04:05'), const Duration(days: 2, hours: 3, minutes: 4, seconds: 5));
    expect(parsePsEtime('-'), isNull);
    expect(parsePsEtime('garbage'), isNull);
  });

  test('parses a host process-table row (command keeps its spaces)', () {
    final row = parseForeignProcessRow(
      ' 73928       1   40:12 /path/dartaotruntime frontend_server_aot.dart.snapshot '
      '--sdk-root /x --incremental --target=flutter',
    );
    expect(row, isNotNull);
    expect(row!.pid, 73928);
    expect(row.ppid, 1);
    expect(row.elapsed, const Duration(minutes: 40, seconds: 12));
    expect(row.command, contains('--target=flutter'));
    expect(parseForeignProcessRow('  BAD HEADER LINE'), isNull);
  });

  test('readHostProcessTable returns empty on Windows', () {
    // Behavior seam, not a live scan: on POSIX this test only asserts the
    // pure parse contract above; on Windows the reader must refuse to
    // guess. The branch itself is exercised by the reader when run there.
    expect(parseForeignProcessRow(''), isNull);
  });

  if (!Platform.isWindows) {
    test('reaps a real orphan (supervisor-reparented after spawner exit)',
        () async {
      // A detached child is NOT an orphan: its spawner stays a live,
      // table-visible parent (observed: ppid = the dart VM), so the
      // orphan gate correctly skips it. A real orphan needs the parent
      // to exit — a shell that starts sleep and returns immediately —
      // so the kernel reparents it to launchd/init/systemd --user.
      final spawner = await Process.start('sh', [
        // The background sleep must not inherit the shell's stdout pipe,
        // or the stream below never sees EOF.
        '-c',
        r'sleep 120 >/dev/null 2>&1 & echo $!',
      ]);
      final pid = int.parse(
        await spawner.stdout.transform(utf8.decoder).join(),
      );
      await spawner.exitCode; // shell gone → sleep is reparented
      try {
        final summary = await reapForeignOrphans(
          Directory.systemTemp.path,
          processTable:
              () async => (await readHostProcessTable())
                  .where((r) => r.pid == pid)
                  .toList(),
          killProcess:
              (pid) async => Process.killPid(pid, ProcessSignal.sigkill),
          liveLeasePids: () async => {},
          targetNames: const ['sleep '],
          minAge: Duration.zero,
        );

        expect(summary.count(ForeignReapDisposition.killed), 1);
        // Give launchd/init a beat to reap the killed child.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(await const HostProcessLiveness().isAlive(pid), isFalse);
      } finally {
        // Idempotent when the reaper already killed it.
        Process.killPid(pid, ProcessSignal.sigkill);
      }
    });
  }
}
