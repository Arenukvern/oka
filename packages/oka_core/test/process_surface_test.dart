// ADR-0018 L1 — the lease lifecycle surface behind `oka processes list` /
// `oka stop`: inventory rendering, and the stop laws (identity-over-pid,
// owned-only enforcement, graceful-first with force as the last rung),
// plus the L2 reconcile sweep. All host interaction goes through
// injectable fakes — no real signals are ever sent.
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

/// Scripted liveness: aliveness/token toggleable, records kills.
class FakeLiveness implements ProcessLiveness {
  FakeLiveness({
    this.alive = true,
    this.token = 'tok-1',
    this.killSucceeds = true,
  });

  bool alive;
  String? token;
  bool killSucceeds;
  final killed = <int>[];

  @override
  Future<bool> isAlive(final int pid) async => alive;

  @override
  Future<String?> identityToken(final int pid) async => token;

  @override
  Future<bool> kill(
    final int pid, {
    final Duration grace = const Duration(seconds: 3),
  }) async {
    killed.add(pid);
    return killSucceeds;
  }
}

ProcessLease lease({
  final String id = 'emulator-oka-emulator',
  final int pid = 4242,
  final String? token = 'tok-1',
  final LeaseOwnership ownership = LeaseOwnership.owned,
  final LeaseStopHint stopHint = const LeaseStopHint(
    tool: 'adb',
    args: ['-s', 'emulator-5554', 'emu', 'kill'],
  ),
}) =>
    ProcessLease(
      id: id,
      pid: pid,
      kind: 'android-emulator',
      identity: {
        'avd': 'oka-emulator',
        processLeasePidTokenKey: ?token,
      },
      scope: LeaseScope.ephemeral,
      ownership: ownership,
      ownerCmd: 'oka run emulator',
      startedAt: DateTime.utc(2026, 9, 10, 12),
      stopHint: stopHint,
    );

void main() {
  late Directory temp;
  late FakeLiveness liveness;
  final hintRuns = <String>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka_surface_');
    liveness = FakeLiveness();
    hintRuns.clear();
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  ProcessLeaseRegistry reg() => ProcessLeaseRegistry(
        Directory('${temp.path}/.oka_cache/processes'),
        liveness: liveness,
      );

  Future<LeaseStopOutcome> stop(
    final String id, {
    final bool force = false,
  }) =>
      stopLease(
        temp.path,
        id,
        liveness: liveness,
        force: force,
        stopVerifyGrace: const Duration(milliseconds: 100),
        pollInterval: const Duration(milliseconds: 10),
        runProcess: (final exe, final args) async {
          hintRuns.add([exe, ...args].join(' '));
          return ProcessResult(0, 0, '', '');
        },
      );

  group('inventoryLeases', () {
    test('lists leases with their reconcile verdicts; empty project → []',
        () async {
      expect(await inventoryLeases(temp.path, liveness: liveness), isEmpty);
      final registry = reg();
      await registry.upsert(lease());
      await registry.upsert(
        lease(
          id: 'chrome-main',
          pid: 0,
          token: null,
        ).copyWith(
          identity: const {'cdp_port': '9222'},
          ownership: LeaseOwnership.borrowed,
        ),
      );
      final entries = await inventoryLeases(temp.path, liveness: liveness);
      expect(entries, hasLength(2));
      final byId = {for (final e in entries) e.lease.id: e};
      expect(byId['emulator-oka-emulator']!.liveness, LeaseLiveness.live);
      // pid 0 → stale by definition.
      expect(byId['chrome-main']!.liveness, LeaseLiveness.deadPid);
      // Human line carries the verdict + identity, never the raw token.
      final line = byId['emulator-oka-emulator']!.toLine();
      expect(line, contains('running'));
      expect(line, contains('avd=oka-emulator'));
      expect(line, isNot(contains('oka:pid_token')));
    });
  });

  group('stopLease laws', () {
    test('absent lease → refused with an actionable message', () async {
      final o = await stop('nope');
      expect(o.ok, isFalse);
      expect(o.action, LeaseStopAction.refused);
      expect(o.error, contains("No process lease 'nope'"));
      expect(o.error, contains('oka processes list'));
      expect(hintRuns, isEmpty);
    });

    test('deadPid → only the record is dropped, nothing signaled', () async {
      final registry = reg();
      await registry.upsert(lease());
      liveness.alive = false;
      final o = await stop('emulator-oka-emulator');
      expect(o.ok, isTrue);
      expect(o.action, LeaseStopAction.recordDropped);
      expect(liveness.killed, isEmpty);
      expect(hintRuns, isEmpty);
      expect(await registry.list(), isEmpty);
    });

    test('reusedPid → record dropped, pid NEVER signaled', () async {
      final registry = reg();
      await registry.upsert(lease());
      // Pid alive but a different process (start-time token mismatch).
      liveness.token = 'tok-RECYCLED';
      final o = await stop('emulator-oka-emulator');
      expect(o.ok, isTrue);
      expect(o.action, LeaseStopAction.recordDropped);
      expect(liveness.killed, isEmpty,
          reason: 'a recycled pid belongs to an innocent process');
      expect(await registry.list(), isEmpty);
    });

    test('unknown identity → refused, record kept for the sweep', () async {
      final registry = reg();
      await registry.upsert(lease(token: null));
      final o = await stop('emulator-oka-emulator');
      expect(o.ok, isFalse);
      expect(o.action, LeaseStopAction.refused);
      expect(o.error, contains('report-never-guess'));
      expect(hintRuns, isEmpty);
      expect(await registry.list(), hasLength(1));
    });

    test('borrowed → refused without --force; --force overrides', () async {
      final registry = reg();
      await registry.upsert(
        lease().copyWith(identity: lease().identity, ownership: LeaseOwnership.borrowed),
      );
      final refused = await stop('emulator-oka-emulator');
      expect(refused.ok, isFalse);
      expect(refused.action, LeaseStopAction.refused);
      expect(refused.error, contains('borrowed'));
      expect(refused.error, contains('--force'));
      expect(hintRuns, isEmpty);

      // Force rung: an explicit override proceeds through the graceful
      // path and the ladder (the process stays alive in this fake, so the
      // force rung is what stops it).
      final forced = await stopLease(
        temp.path,
        'emulator-oka-emulator',
        liveness: liveness,
        force: true,
        stopVerifyGrace: const Duration(milliseconds: 100),
        pollInterval: const Duration(milliseconds: 10),
        runProcess: (final exe, final args) async {
          hintRuns.add([exe, ...args].join(' '));
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(forced.ok, isTrue);
      expect(forced.action, LeaseStopAction.stopped);
      expect(hintRuns, ['adb -s emulator-5554 emu kill']);
      expect(liveness.killed, [4242]);
    });

    test('live+owned → graceful hint runs, death verified, record removed',
        () async {
      final registry = reg();
      await registry.upsert(lease());
      // The graceful hint actually kills the process (it stops being
      // alive) — the verify window observes the death, no force needed.
      final o = await stopLease(
        temp.path,
        'emulator-oka-emulator',
        liveness: liveness,
        stopVerifyGrace: const Duration(milliseconds: 100),
        pollInterval: const Duration(milliseconds: 10),
        runProcess: (final exe, final args) async {
          hintRuns.add([exe, ...args].join(' '));
          liveness.alive = false;
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(o.ok, isTrue);
      expect(o.action, LeaseStopAction.stopped);
      expect(hintRuns, ['adb -s emulator-5554 emu kill']);
      expect(liveness.killed, isEmpty,
          reason: 'graceful first — no force needed');
      expect(await registry.list(), isEmpty);
    });

    test('graceful hint ignored → force rung escalates', () async {
      final registry = reg();
      await registry.upsert(lease());
      // Process stays alive through the verify window → force.
      final o = await stop('emulator-oka-emulator');
      expect(o.ok, isTrue);
      expect(o.action, LeaseStopAction.stopped);
      expect(liveness.killed, [4242],
          reason: 'force is the last rung of the ladder');
      expect(await registry.list(), isEmpty);
    });

    test('hint fails → force rung rescues (ladder); both fail → failed',
        () async {
      final registry = reg();
      await registry.upsert(lease());
      // Hint exits 1, but the force rung still stops the process.
      final o = await stop('emulator-oka-emulator');
      expect(o.ok, isTrue);
      expect(o.action, LeaseStopAction.stopped);
      expect(liveness.killed, [4242]);
      expect(await registry.list(), isEmpty);

      // If even the force rung fails, the lease stays for reconciliation.
      await registry.upsert(lease());
      liveness.killSucceeds = false;
      final o2 = await stop('emulator-oka-emulator');
      expect(o2.ok, isFalse);
      expect(o2.action, LeaseStopAction.failed);
      expect(o2.error, contains('still alive'));
      expect(await registry.list(), hasLength(1));
    });

    test('pid 0 + hint-only (adb emu kill) → hint path, record removed',
        () async {
      final registry = reg();
      await registry.upsert(
        lease(
          pid: 0,
          token: null,
        ).copyWith(
          identity: const {'avd': 'oka-emulator', 'serial': 'emulator-5554'},
          stopHint: const LeaseStopHint(
            tool: 'adb',
            args: ['-s', 'emulator-5554', 'emu', 'kill'],
          ),
        ),
      );
      final o = await stop('emulator-oka-emulator');
      expect(o.ok, isTrue);
      expect(o.action, LeaseStopAction.stopped);
      expect(hintRuns, ['adb -s emulator-5554 emu kill']);
      expect(await registry.list(), isEmpty);
    });
  });
  group('reconcileLeases (L2 sweep)', () {
    late Directory temp;
    late FakeLiveness liveness;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('oka_sweep_');
      liveness = FakeLiveness();
    });
    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    ProcessLeaseRegistry reg() => ProcessLeaseRegistry(
          Directory('${temp.path}/.oka_cache/processes'),
          liveness: liveness,
        );

    test('provably-stale records are dropped; nothing is ever signaled',
        () async {
      final registry = reg();
      await registry.upsert(lease());
      liveness.alive = false; // process gone
      final summary = await reconcileLeases(temp.path, liveness: liveness);
      expect(summary.droppedStale, ['emulator-oka-emulator']);
      expect(summary.clean, isTrue);
      expect(liveness.killed, isEmpty);
      expect(await registry.list(), isEmpty);
    });

    test('recycled pid → record dropped, pid never signaled', () async {
      final registry = reg();
      await registry.upsert(lease());
      liveness.token = 'tok-RECYCLED';
      final summary = await reconcileLeases(temp.path, liveness: liveness);
      expect(summary.droppedStale, ['emulator-oka-emulator']);
      expect(liveness.killed, isEmpty,
          reason: 'a recycled pid belongs to an innocent process');
    });

    test('live owned+ephemeral → orphan-suspect: reported, NOT stopped',
        () async {
      final registry = reg();
      await registry.upsert(lease());
      final summary = await reconcileLeases(temp.path, liveness: liveness);
      expect(summary.orphans, ['emulator-oka-emulator']);
      expect(liveness.killed, isEmpty,
          reason: 'inspection-time sweeps never auto-stop: the emulator '
              'posture deliberately keeps it for reuse');
      expect(await registry.list(), hasLength(1));
      final lines = summary.describeLines().join('\n');
      expect(lines, contains('orphaned'));
      expect(lines, contains('oka stop <id>'));
    });

    test('stopOrphans hardens the sweep for hermetic harnesses', () async {
      final registry = reg();
      await registry.upsert(lease());
      final hintRuns = <String>[];
      final summary = await reconcileLeases(
        temp.path,
        liveness: liveness,
        stopOrphans: true,
        stopVerifyGrace: const Duration(milliseconds: 100),
        runProcess: (final exe, final args) async {
          hintRuns.add([exe, ...args].join(' '));
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(summary.orphans, ['emulator-oka-emulator']);
      expect(hintRuns, ['adb -s emulator-5554 emu kill'],
          reason: 'graceful first');
      // Stopped through the identity-graded ladder (process still alive in
      // the fake → force rung).
      expect(liveness.killed, [4242]);
      expect(await registry.list(), isEmpty);
    });

    test('borrowed and persistent live leases are kept, never touched',
        () async {
      final registry = reg();
      await registry.upsert(
        lease(
          id: 'a-borrowed',
        ).copyWith(identity: lease().identity, ownership: LeaseOwnership.borrowed),
      );
      await registry.upsert(
        lease(id: 'b-persistent').copyWith(
          identity: lease().identity,
          ownership: LeaseOwnership.owned,
        ),
      );
      // Persistent is scope-level: rebuild via copyWith on scope? copyWith
      // keeps scope — write directly instead.
      await registry.delete('b-persistent');
      await registry.upsert(
        ProcessLease(
          id: 'b-persistent',
          pid: 5151,
          kind: 'android-emulator',
          identity: lease().identity,
          scope: LeaseScope.persistent,
          ownership: LeaseOwnership.owned,
          ownerCmd: 'oka run emulator',
          startedAt: DateTime.utc(2026, 9, 10, 12),
          stopHint: const LeaseStopHint(tool: 'kill', args: ['5151']),
        ),
      );
      final summary = await reconcileLeases(temp.path, liveness: liveness);
      expect(summary.borrowed, ['a-borrowed']);
      expect(summary.persistent, ['b-persistent']);
      expect(summary.orphans, isEmpty);
      expect(liveness.killed, isEmpty);
      expect(await registry.list(), hasLength(2));
    });

    test('unverifiable identity → reported, kept, never signaled', () async {
      final registry = reg();
      await registry.upsert(lease(token: null));
      final summary = await reconcileLeases(temp.path, liveness: liveness);
      expect(summary.unverifiable, ['emulator-oka-emulator']);
      expect(await registry.list(), hasLength(1));
    });
  });
}
