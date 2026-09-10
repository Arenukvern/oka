// ADR-0018 L0 — process leases: record round-trip, registry atomicity +
// reconcile semantics (dead pid, pid reuse, unknown identity), the
// identity-over-pid kill gate, and the Linux /proc starttime parser.
//
// All host interaction goes through the injectable [ProcessLiveness] seam
// (scripted fakes) — no real signals are ever sent.
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

/// Scripted liveness: fixed aliveness + identity token, records kills.
class FakeLiveness implements ProcessLiveness {
  FakeLiveness({this.alive = true, this.token = 'tok-1'});

  bool alive;
  String? token;
  final killed = <int>[];

  @override
  Future<bool> isAlive(final int pid) async => alive;

  @override
  Future<String?> identityToken(final int pid) async => token;

  @override
  Future<bool> kill(final int pid, {final Duration grace = const Duration(seconds: 3)}) async {
    killed.add(pid);
    return true;
  }
}

ProcessLease lease({
  final int pid = 4242,
  final Map<String, String> identity = const {
    'avd': 'oka-emulator',
    processLeasePidTokenKey: 'tok-1',
  },
  final LeaseOwnership ownership = LeaseOwnership.owned,
}) =>
    ProcessLease(
      id: 'emulator-oka-emulator',
      pid: pid,
      kind: 'android-emulator',
      identity: identity,
      scope: LeaseScope.ephemeral,
      ownership: ownership,
      ownerCmd: 'oka run emulator',
      startedAt: DateTime.utc(2026, 9, 10, 12),
      stopHint: const LeaseStopHint(
        tool: 'adb',
        args: ['-s', 'emulator-5554', 'emu', 'kill'],
      ),
    );

void main() {
  group('ProcessLease record', () {
    test('JSON round-trip preserves every field (ADR §1 shape)', () {
      final l = lease();
      final decoded = ProcessLease.fromJsonString(l.toJsonString());
      expect(decoded, l);
      expect(decoded.identity, l.identity);
      expect(decoded.stopHint, l.stopHint);
      expect(decoded.startedAt, DateTime.utc(2026, 9, 10, 12));
    });

    test('wire shape matches the ADR §1 JSON keys verbatim', () {
      final json = lease().toJson();
      expect(
        json.keys,
        containsAll([
          'id',
          'pid',
          'kind',
          'identity',
          'scope',
          'ownership',
          'owner_cmd',
          'started_at',
          'stop_hint',
        ]),
      );
      expect(json['owner_cmd'], 'oka run emulator');
      expect(
        (json['stop_hint']! as Map)['args'],
        ['-s', 'emulator-5554', 'emu', 'kill'],
      );
    });

    test('copyWith flips ownership to borrowed and nothing else', () {
      final l = lease();
      final adopted = l.copyWith(
        identity: {...l.identity, 'serial': 'emulator-5554'},
        ownership: LeaseOwnership.borrowed,
      );
      expect(adopted.ownership, LeaseOwnership.borrowed);
      expect(adopted.identity['serial'], 'emulator-5554');
      expect(adopted.id, l.id);
      expect(adopted.pid, l.pid);
      expect(adopted.startedAt, l.startedAt);
    });

    test('unknown scope/ownership labels fail closed', () {
      expect(
        () => LeaseScope.fromLabel('forever'),
        throwsFormatException,
      );
      expect(
        () => LeaseOwnership.fromLabel('mine'),
        throwsFormatException,
      );
    });
  });

  group('ProcessLeaseRegistry', () {
    late Directory dir;
    late ProcessLeaseRegistry registry;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('oka_lease_reg_');
      registry = ProcessLeaseRegistry(dir);
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('upsert/read/list/delete round-trip; list sorted by id', () async {
      expect(await registry.list(), isEmpty);
      expect(await registry.read('emulator-oka-emulator'), isNull);

      await registry.upsert(lease(pid: 1));
      final aFirst = ProcessLease(
        id: 'a-first',
        pid: 3,
        kind: 'android-emulator',
        identity: const {'avd': 'a'},
        scope: LeaseScope.ephemeral,
        ownership: LeaseOwnership.owned,
        ownerCmd: 'oka run emulator',
        startedAt: DateTime.utc(2026, 9, 10, 12),
        stopHint: const LeaseStopHint(tool: 'adb'),
      );
      await registry.upsert(aFirst);

      final listed = await registry.list();
      expect(listed.map((final l) => l.id).toList(), [
        'a-first',
        'emulator-oka-emulator',
      ]);
      expect((await registry.read('a-first'))?.pid, 3);

      // Upsert replaces — one file per id, never two.
      await registry.upsert(lease(pid: 99));
      final after = await registry.list();
      expect(after.length, 2);
      expect(after.singleWhere((final l) => l.id == 'emulator-oka-emulator').pid, 99);

      expect(await registry.delete('a-first'), isTrue);
      expect(await registry.delete('a-first'), isFalse);
      expect((await registry.list()).length, 1);
    });

    test('temp litter from a crashed write is ignored by list', () async {
      await registry.upsert(lease());
      File(
        '${dir.path}/emulator-oka-emulator.json.123.tmp',
      ).writeAsStringSync('garbage');
      final listed = await registry.list();
      expect(listed.length, 1);
      expect(listed.single.pid, 4242);
    });

    test('corrupt records are skipped, never fatal (advisory registry)',
        () async {
      await registry.upsert(lease());
      File('${dir.path}/broken.json').writeAsStringSync('{not json');
      final listed = await registry.list();
      expect(listed.length, 1);
    });

    test('forProject roots at .oka_cache/processes', () {
      final r = ProcessLeaseRegistry.forProject('/tmp/some-project');
      expect(
        r.directory.path,
        endsWith('${Platform.pathSeparator}.oka_cache${Platform.pathSeparator}processes'),
      );
    });
  });

  group('lease liveness reconcile (crash-recovery primitive)', () {
    late Directory dir;
    late FakeLiveness liveness;
    late ProcessLeaseRegistry registry;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('oka_lease_live_');
      liveness = FakeLiveness();
      registry = ProcessLeaseRegistry(dir, liveness: liveness);
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('live: pid alive + start-time token matches', () async {
      liveness.token = 'tok-1';
      expect(
        await registry.checkLiveness(lease()),
        LeaseLiveness.live,
      );
    });

    test('deadPid: process gone — stale, safe to delete', () async {
      liveness.alive = false;
      expect(
        await registry.checkLiveness(lease()),
        LeaseLiveness.deadPid,
      );
    });

    test('deadPid: pid 0 (borrowed-by-discovery) is stale by definition',
        () async {
      expect(
        await registry.checkLiveness(lease(pid: 0)),
        LeaseLiveness.deadPid,
      );
    });

    test('reusedPid: pid alive but start-time token differs — never killed',
        () async {
      liveness.token = 'tok-RECYCLED';
      expect(
        await registry.checkLiveness(lease()),
        LeaseLiveness.reusedPid,
      );
    });

    test('unknown: no recorded token — report, never guess', () async {
      liveness.token = 'tok-1';
      expect(
        await registry.checkLiveness(
          lease(identity: const {'avd': 'oka-emulator'}),
        ),
        LeaseLiveness.unknown,
      );
    });

    test('unknown: platform seam throws — report, never guess', () async {
      final throwing = _ThrowingLiveness();
      final r = ProcessLeaseRegistry(dir, liveness: throwing);
      expect(
        await r.checkLiveness(lease()),
        LeaseLiveness.unknown,
      );
    });
  });

  group('identity-over-pid kill gate', () {
    test('verified: recorded token matches the live token', () async {
      final liveness = FakeLiveness();
      expect(
        await verifyKillIdentity(liveness, 4242, 'tok-1'),
        KillIdentity.verified,
      );
    });

    test('recycled: live token differs — NEVER signal', () async {
      final liveness = FakeLiveness(token: 'tok-NEW');
      expect(
        await verifyKillIdentity(liveness, 4242, 'tok-1'),
        KillIdentity.recycled,
      );
      expect(liveness.killed, isEmpty,
          reason: 'a recycled pid belongs to an innocent process');
    });

    test('unknown: no recorded token, dead pid, or throwing seam', () async {
      expect(
        await verifyKillIdentity(FakeLiveness(token: null), 4242, 'tok-1'),
        KillIdentity.unknown,
      );
      expect(
        await verifyKillIdentity(FakeLiveness(), 0, 'tok-1'),
        KillIdentity.unknown,
      );
      expect(
        await verifyKillIdentity(_ThrowingLiveness(), 4242, 'tok-1'),
        KillIdentity.unknown,
      );
    });
  });

  group('parseLinuxProcStatStarttime (pure, golden)', () {
    test('field 22 after a comm field containing spaces/parens', () {
      // state is field 3 → index 0 after ')'; starttime is field 22 →
      // index 19. comm deliberately contains spaces and parentheses.
      const stat = '4242 (a browser (x)) R 1 4242 4242 0 -1 4194304 '
          '100 0 0 0 5 3 0 0 777 1 2 0 987654 100 0 0 0 0 0';
      expect(parseLinuxProcStatStarttime(stat), '987654');
    });

    test('short record → null (never throws)', () {
      expect(parseLinuxProcStatStarttime('1 (x) R'), isNull);
      expect(parseLinuxProcStatStarttime(''), isNull);
    });
  });
}

final class _ThrowingLiveness implements ProcessLiveness {
  @override
  Future<bool> isAlive(final int pid) async => throw StateError('seam down');

  @override
  Future<String?> identityToken(final int pid) async =>
      throw StateError('seam down');

  @override
  Future<bool> kill(final int pid, {final Duration grace = const Duration(seconds: 3)}) async =>
      throw StateError('seam down');
}
