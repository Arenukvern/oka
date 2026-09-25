/// Durable cross-project registry for managed session state (ADR-0025).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'session_state.dart';

/// One session-state registry parse or filesystem issue.
final class SessionStateRegistryIssue {
  const SessionStateRegistryIssue({required this.path, required this.message});

  final String path;
  final String message;

  Map<String, Object?> toJson() => {'path': path, 'message': message};
}

/// A non-mutating registry snapshot. Invalid records remain visible as issues.
final class SessionStateRegistrySnapshot {
  const SessionStateRegistrySnapshot({
    this.leases = const [],
    this.issues = const [],
  });

  final List<SessionStateLease> leases;
  final List<SessionStateRegistryIssue> issues;
}

/// Stable Oka host identity plus identity of the current boot.
final class SessionStateHostIdentity {
  const SessionStateHostIdentity({required this.hostId, required this.bootId});

  final String hostId;
  final String bootId;

  bool get canProveSameBoot =>
      hostId.isNotEmpty && bootId.isNotEmpty && bootId != 'unsupported';
}

/// Error from a state registry operation. Messages are safe to show in CLI.
final class SessionStateRegistryException implements Exception {
  const SessionStateRegistryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Durable state records stored outside a project's `.oka_cache`.
///
/// Mutating operations serialize by resource key and compare generations.
/// Registry files are advisory state, not executable instructions. Corrupt or
/// future-schema records are reported and never overwritten.
final class SessionStateRegistry {
  SessionStateRegistry(
    this.directory, {
    String? bootId,
    String Function()? idGenerator,
  }) : _bootIdOverride = bootId,
       _idGenerator = idGenerator ?? _randomId;

  /// The user-global registry rooted under the platform user's home.
  factory SessionStateRegistry.forCurrentUser({
    String? homeDirectory,
    String? bootId,
    String Function()? idGenerator,
  }) {
    final home =
        homeDirectory ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['APPDATA'];
    if (home == null || home.trim().isEmpty) {
      throw const SessionStateRegistryException(
        'Cannot locate the user home directory for the session-state registry. '
        'Set HOME, USERPROFILE, or APPDATA; the registry will not fall back '
        'to the current project directory.',
      );
    }
    return SessionStateRegistry(
      Directory(p.join(home, '.oka', 'session-states')),
      bootId: bootId,
      idGenerator: idGenerator,
    );
  }

  final String? _bootIdOverride;
  final String Function() _idGenerator;

  /// Directory containing one JSON record per opaque acquisition id.
  final Directory directory;

  File _recordFile(final String id) {
    if (!_validId(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid session-state id.');
    }
    return File(p.join(directory.path, '$id.json'));
  }

  /// Generates a non-user-derived, path-safe acquisition id.
  String newId() => _idGenerator();

  /// Host UUID is persisted once; boot id is read for every invocation.
  Future<SessionStateHostIdentity> hostIdentity({bool create = true}) async {
    if (!create) {
      final registryType = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (registryType == FileSystemEntityType.notFound) {
        return SessionStateHostIdentity(
          hostId: '',
          bootId: _bootIdOverride ?? await _currentBootId(),
        );
      }
      if (registryType != FileSystemEntityType.directory ||
          await _hasLinkedAncestor(directory.path)) {
        throw SessionStateRegistryException(
          'Session-state registry "${directory.path}" is not a safe real '
          'directory.',
        );
      }
      final hostFile = File(p.join(directory.path, 'host.json'));
      final hostType = await FileSystemEntity.type(
        hostFile.path,
        followLinks: false,
      );
      if (hostType == FileSystemEntityType.notFound) {
        return SessionStateHostIdentity(
          hostId: '',
          bootId: _bootIdOverride ?? await _currentBootId(),
        );
      }
      if (hostType != FileSystemEntityType.file) {
        throw const SessionStateRegistryException(
          'Host identity record is not a regular file.',
        );
      }
      final decoded = jsonDecode(await hostFile.readAsString());
      if (decoded is! Map ||
          decoded['schema_version'] != 1 ||
          decoded['host_id'] is! String ||
          (decoded['host_id'] as String).isEmpty) {
        throw const SessionStateRegistryException(
          'Host identity record is corrupt or has an unknown schema.',
        );
      }
      return SessionStateHostIdentity(
        hostId: decoded['host_id'] as String,
        bootId: _bootIdOverride ?? await _currentBootId(),
      );
    }
    await _ensureRegistryDirectory();
    return _withInProcessLock(_registryLockKey, () async {
      final lock = await File(
        p.join(directory.path, 'registry.lock'),
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        await _reapAbandonedTemporaryFiles();
        final hostFile = File(p.join(directory.path, 'host.json'));
        String hostId;
        if (await hostFile.exists()) {
          final decoded = jsonDecode(await hostFile.readAsString());
          if (decoded is! Map || decoded['schema_version'] != 1) {
            throw const SessionStateRegistryException(
              'Host identity record has an unknown schema; refusing to replace it.',
            );
          }
          final value = decoded['host_id'];
          if (value is! String || value.isEmpty) {
            throw const SessionStateRegistryException(
              'Host identity record is corrupt; refusing to replace it.',
            );
          }
          hostId = value;
        } else {
          hostId = _randomId();
          final temporary = File(
            p.join(directory.path, '.host.${_randomId()}.tmp'),
          );
          await temporary.writeAsString(
            const JsonEncoder.withIndent(
              '  ',
            ).convert({'schema_version': 1, 'host_id': hostId}),
            flush: true,
          );
          await temporary.rename(hostFile.path);
        }
        return SessionStateHostIdentity(
          hostId: hostId,
          bootId: _bootIdOverride ?? await _currentBootId(),
        );
      } finally {
        await lock.close();
      }
    });
  }

  /// Read all records, retaining parse errors as reportable issues.
  Future<SessionStateRegistrySnapshot> inspect() async {
    final leases = <SessionStateLease>[];
    final issues = <SessionStateRegistryIssue>[];
    try {
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        return const SessionStateRegistrySnapshot();
      }
      if (type != FileSystemEntityType.directory) {
        return SessionStateRegistrySnapshot(
          issues: [
            SessionStateRegistryIssue(
              path: directory.path,
              message: 'Session-state registry is not a real directory.',
            ),
          ],
        );
      }
      if (await _hasLinkedAncestor(directory.path)) {
        return SessionStateRegistrySnapshot(
          issues: [
            SessionStateRegistryIssue(
              path: directory.path,
              message: 'Session-state registry is beneath a symbolic link.',
            ),
          ],
        );
      }
      await for (final entity in directory.list(followLinks: false)) {
        if (!entity.path.endsWith('.json') ||
            p.basename(entity.path) == 'host.json') {
          continue;
        }
        if (entity is! File ||
            await FileSystemEntity.type(entity.path, followLinks: false) !=
                FileSystemEntityType.file) {
          issues.add(
            SessionStateRegistryIssue(
              path: entity.path,
              message: 'Session-state record is not a regular file.',
            ),
          );
          continue;
        }
        try {
          final lease = SessionStateLease.fromJson(
            jsonDecode(await entity.readAsString()),
          );
          final fileId = p
              .basename(entity.path)
              .substring(0, p.basename(entity.path).length - '.json'.length);
          if (!_validId(fileId) || lease.id != fileId) {
            throw const FormatException(
              'Session-state record id does not match its opaque filename.',
            );
          }
          leases.add(lease);
        } on Object catch (error) {
          issues.add(
            SessionStateRegistryIssue(
              path: entity.path,
              message: error.toString(),
            ),
          );
        }
      }
    } on Object catch (error) {
      issues.add(
        SessionStateRegistryIssue(path: directory.path, message: '$error'),
      );
    }
    leases.sort((final a, final b) => a.id.compareTo(b.id));
    issues.sort((final a, final b) => a.path.compareTo(b.path));
    return SessionStateRegistrySnapshot(
      leases: List.unmodifiable(leases),
      issues: List.unmodifiable(issues),
    );
  }

  /// Reads one valid record or returns null when absent.
  Future<SessionStateLease?> read(final String id) async {
    final file = _recordFile(id);
    if (!await file.exists()) return null;
    return SessionStateLease.fromJson(jsonDecode(await file.readAsString()));
  }

  /// Creates a new reservation; existing ids are never overwritten.
  Future<void> create(final SessionStateLease lease) async {
    _validateLease(lease);
    await _withRegistryLock(() async {
      final file = _recordFile(lease.id);
      if (await file.exists()) {
        throw SessionStateRegistryException(
          'Session-state acquisition "${lease.id}" already exists.',
        );
      }
      await _writeAtomic(file, lease);
    });
  }

  /// Compare-and-swap update. A stale writer cannot overwrite newer state.
  Future<SessionStateLease> update(
    final SessionStateLease lease, {
    required int expectedGeneration,
  }) {
    _validateLease(lease);
    return _withRegistryLock(() async {
      final file = _recordFile(lease.id);
      if (!await file.exists()) {
        throw SessionStateRegistryException(
          'Session-state acquisition "${lease.id}" no longer exists.',
        );
      }
      final current = SessionStateLease.fromJson(
        jsonDecode(await file.readAsString()),
      );
      if (current.generation != expectedGeneration) {
        throw SessionStateRegistryException(
          'Session-state "${lease.id}" changed concurrently '
          '(expected generation $expectedGeneration, found ${current.generation}).',
        );
      }
      final next = lease.copyWith(generation: current.generation + 1);
      await _writeAtomic(file, next);
      return next;
    });
  }

  /// Removes a record only after the caller has confirmed disposal.
  Future<bool> deleteDisposed(
    final String id, {
    required int expectedGeneration,
  }) => _withRegistryLock(() async {
    final file = _recordFile(id);
    if (!await file.exists()) return false;
    final current = SessionStateLease.fromJson(
      jsonDecode(await file.readAsString()),
    );
    if (current.generation != expectedGeneration) {
      throw SessionStateRegistryException(
        'Session-state "$id" changed concurrently before record removal.',
      );
    }
    if (current.phase != SessionStatePhase.disposed) {
      throw SessionStateRegistryException(
        'Session-state "$id" cannot be removed before disposal is confirmed.',
      );
    }
    await file.delete();
    return true;
  });

  /// Holds a cross-process lock for all mutations of one logical resource.
  Future<T> withResourceLock<T>(
    final String logicalResourceKey,
    final Future<T> Function() action,
  ) async {
    if (logicalResourceKey.isEmpty || logicalResourceKey.length > 1024) {
      throw ArgumentError.value(
        logicalResourceKey,
        'logicalResourceKey',
        'Must be 1–1024 characters.',
      );
    }
    await _ensureRegistryDirectory();
    final digest = sha256.convert(utf8.encode(logicalResourceKey)).toString();
    final key = '$_canonicalDirectory:resource:$digest';
    return _withInProcessLock(key, () async {
      final file = File(p.join(directory.path, 'resource-$digest.lock'));
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.blockingExclusive);
        return await action();
      } finally {
        await handle.close();
      }
    });
  }

  Future<T> _withRegistryLock<T>(final Future<T> Function() action) async {
    await _ensureRegistryDirectory();
    return _withInProcessLock(_registryLockKey, () async {
      final lock = await File(
        p.join(directory.path, 'registry.lock'),
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        await _reapAbandonedTemporaryFiles();
        return await action();
      } finally {
        await lock.close();
      }
    });
  }

  String get _canonicalDirectory => p.normalize(p.absolute(directory.path));

  String get _registryLockKey => '$_canonicalDirectory:registry';

  Future<void> _reapAbandonedTemporaryFiles() async {
    final recordTemp = RegExp(r'^\.[a-f0-9]{32}\.[a-f0-9]{32}\.tmp$');
    final hostTemp = RegExp(r'^\.host\.[a-f0-9]{32}\.tmp$');
    try {
      await for (final entity in directory.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (!recordTemp.hasMatch(name) && !hostTemp.hasMatch(name)) continue;
        if (entity is File &&
            await FileSystemEntity.type(entity.path, followLinks: false) ==
                FileSystemEntityType.file) {
          await entity.delete();
        }
      }
    } on FileSystemException catch (error) {
      throw SessionStateRegistryException(
        'Could not inspect abandoned session-state registry writes: $error',
      );
    }
  }

  Future<void> _ensureRegistryDirectory() async {
    if (await _hasLinkedAncestor(directory.path)) {
      throw SessionStateRegistryException(
        'Session-state registry "${directory.path}" is beneath a symbolic '
        'link; refusing to write outside its declared location.',
      );
    }
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw SessionStateRegistryException(
        'Session-state registry "${directory.path}" is not a real directory.',
      );
    }
    if (await _hasLinkedAncestor(directory.path)) {
      throw SessionStateRegistryException(
        'Session-state registry "${directory.path}" changed to a symbolic '
        'link; refusing to write.',
      );
    }
    await _restrictRegistryDirectoryPermissions();
  }

  Future<void> _restrictRegistryDirectoryPermissions() async {
    // dart:io exposes filesystem mode bits for inspection but has no API to
    // set them. On POSIX, invoke chmod only when the directory is not already
    // owner-only; an inability to inspect, change, or verify the mode fails
    // closed before any registry lock is opened. Windows ACLs are inherited
    // from the user's profile and cannot be inspected or set with dart:io.
    if (!Platform.isLinux && !Platform.isMacOS) return;

    const permissionMask = 0x1ff; // 0777
    const ownerOnlyMode = 0x1c0; // 0700

    FileStat stat;
    try {
      stat = await FileStat.stat(directory.path);
    } on Object catch (error) {
      throw SessionStateRegistryException(
        'Could not inspect session-state registry permissions: $error',
      );
    }
    if (stat.type != FileSystemEntityType.directory) {
      throw SessionStateRegistryException(
        'Session-state registry "${directory.path}" is not a real directory.',
      );
    }
    if ((stat.mode & permissionMask) == ownerOnlyMode) return;

    ProcessResult result;
    try {
      result = await Process.run('chmod', ['700', directory.path]);
    } on Object catch (error) {
      throw SessionStateRegistryException(
        'Could not restrict session-state registry permissions: $error',
      );
    }
    if (result.exitCode != 0) {
      throw SessionStateRegistryException(
        'Could not restrict session-state registry permissions: '
        '${result.stderr.toString().trim()}',
      );
    }

    try {
      stat = await FileStat.stat(directory.path);
    } on Object catch (error) {
      throw SessionStateRegistryException(
        'Could not verify session-state registry permissions: $error',
      );
    }
    if (stat.type != FileSystemEntityType.directory ||
        (stat.mode & permissionMask) != ownerOnlyMode) {
      throw const SessionStateRegistryException(
        'Session-state registry permissions are not owner-only after chmod.',
      );
    }
  }

  Future<void> _writeAtomic(
    final File target,
    final SessionStateLease lease,
  ) async {
    final temporary = File(
      p.join(directory.path, '.${lease.id}.${_idGenerator()}.tmp'),
    );
    try {
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(lease.toJson())}\n',
        flush: true,
      );
      await temporary.rename(target.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  void _validateLease(final SessionStateLease lease) {
    _recordFile(lease.id);
    if (!_validId(lease.id)) {
      throw ArgumentError.value(lease.id, 'id', 'Invalid session-state id.');
    }
    if (lease.workflowId.isEmpty ||
        lease.workflowVersion < 1 ||
        lease.logicalResourceKey.isEmpty ||
        lease.generation < 0 ||
        lease.ownerPid < 0 ||
        lease.attemptCount < 0) {
      throw ArgumentError('Session-state lease contains invalid fields.');
    }
    if (lease.ownership == SessionStateOwnership.caller &&
        lease.acquisitionMode != SessionStateAcquisitionMode.borrowed) {
      throw ArgumentError(
        'Caller-owned session state must be acquired as borrowed.',
      );
    }
    if (lease.acquisitionMode == SessionStateAcquisitionMode.borrowed &&
        lease.ownership == SessionStateOwnership.oka) {
      throw ArgumentError('Borrowed session state cannot be marked Oka-owned.');
    }
    if (lease.resourceKind == SessionStateResourceKind.opaque &&
        lease.ownership == SessionStateOwnership.oka &&
        lease.retention != SessionStateRetention.persistent) {
      throw ArgumentError(
        'Oka-owned opaque state must remain persistent until an explicit '
        'provider-specific disposal contract exists.',
      );
    }
  }
}

final Map<String, Completer<void>> _processLocalLocks = {};

Future<T> _withInProcessLock<T>(
  final String key,
  final Future<T> Function() action,
) async {
  final previous = _processLocalLocks[key]?.future ?? Future<void>.value();
  final release = Completer<void>();
  _processLocalLocks[key] = release;
  await previous;
  try {
    return await action();
  } finally {
    if (identical(_processLocalLocks[key], release)) {
      _processLocalLocks.remove(key);
    }
    release.complete();
  }
}

bool _validId(final String value) => RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

Future<bool> _hasLinkedAncestor(final String path) async {
  var current = p.normalize(p.absolute(path));
  while (true) {
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      return true;
    }
    final parent = p.dirname(current);
    if (parent == current) return false;
    current = parent;
  }
}

String _randomId() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((final byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Future<String> _currentBootId() async {
  if (Platform.isLinux) {
    try {
      final value = await File(
        '/proc/sys/kernel/random/boot_id',
      ).readAsString();
      if (value.trim().isNotEmpty) return value.trim();
    } on Object {
      return 'unsupported';
    }
  } else if (Platform.isMacOS) {
    try {
      final result = await Process.run('sysctl', ['-n', 'kern.boottime']);
      if (result.exitCode == 0) {
        final match = RegExp(
          r'sec\s*=\s*(\d+)',
        ).firstMatch(result.stdout.toString());
        if (match != null) return 'macos-${match.group(1)}';
      }
    } on Object {
      return 'unsupported';
    }
  } else if (Platform.isWindows) {
    try {
      const command =
          '(Get-CimInstance -ClassName Win32_OperatingSystem '
          '-Property LastBootUpTime).LastBootUpTime.ToUniversalTime().Ticks';
      final result = await Process.run('powershell.exe', [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        command,
      ]);
      final ticks = result.stdout.toString().trim();
      if (result.exitCode == 0 && RegExp(r'^\d{1,20}$').hasMatch(ticks)) {
        return 'windows-$ticks';
      }
    } on Object {
      return 'unsupported';
    }
  }
  return 'unsupported';
}
