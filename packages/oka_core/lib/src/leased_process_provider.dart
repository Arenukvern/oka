/// The oka adapter (ADR-0026 R3.1): a [ResourceProvider] for process-backed
/// components that maps the composition contract onto oka's own lifecycle
/// machinery — the process seam for spawn/stop, the lease registry for
/// durable identity, identity-before-signal and owned-only teardown from
/// ADR-0018.
///
/// One provider instance per component (constructor injection, the house
/// style): the command is a constructor parameter, the lease registry is
/// shared through the composition root.
///
/// ```dart
/// final registry = ProcessLeaseRegistry.forProject(projectDir);
/// final api = Component(
///   id: 'api',
///   provider: LeasedProcessProvider(
///     leaseId: 'my-api',
///     command: const ProcessCommand('dart', ['run', 'bin/server.dart']),
///     registry: registry,
///   ),
///   provides: const [port],
///   readiness: const HandshakeLine(pattern: 'listening on '),
/// );
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:resource_composition/resource_composition.dart';

import 'process_lease.dart';
import 'process_lease_registry.dart';
import 'process_liveness.dart';
import 'process_tree.dart';

/// The command a [LeasedProcessProvider] spawns — argv, never shell
/// concatenation (ADR-0026 decision 11).
final class ProcessCommand {
  const ProcessCommand(this.executable, [this.arguments = const <String>[]]);

  final String executable;
  final List<String> arguments;

  @override
  String toString() => [executable, ...arguments].join(' ');
}

/// Spawns a command as a leased, composition-managed component.
final class LeasedProcessProvider implements ResourceProvider {
  const LeasedProcessProvider({
    required this.leaseId,
    required this.command,
    required this.registry,
    this.kind = 'process',
    this.runToExit = false,
    this.workingDirectory,
    this.environment,
    this.liveness = const HostProcessLiveness(),
    this.treeProbe = const HostProcessTreeProbe(),
  });

  /// Stable lease id — the registry file name (`<id>.json`).
  final String leaseId;
  final ProcessCommand command;
  final ProcessLeaseRegistry registry;
  final String kind;

  /// Jobs complete only after exit zero; cancellation stops the owned tree.
  /// Services retain the default readiness-return behavior.
  final bool runToExit;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final ProcessLiveness liveness;
  final ProcessTreeProbe treeProbe;

  @override
  ProviderCapabilities get capabilities =>
      const ProviderCapabilities(readinessProbe: true, durableIdentity: true);

  @override
  Future<StartReport> start(StartRequest request) async {
    if (request.cancellation.isCancelled) {
      throw StartCancelled(request.component.id);
    }
    if (request.mode == StartMode.attach) {
      throw StateError(
        'LeasedProcessProvider("$leaseId") owns what it spawns; attach is '
        'not a capability. Compose an attach-only provider instead.',
      );
    }
    final Process process;
    try {
      process = await Process.start(
        command.executable,
        command.arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } on Object catch (error) {
      throw StateError('spawn failed for "$leaseId": $error');
    }

    String? identityToken;
    try {
      identityToken = await liveness.identityToken(process.pid);
    } on Object {
      identityToken = null;
    }

    // Record the owned lease immediately (ADR-0018 §1): a crash after this
    // point leaves a reconcilable record, not an invisible orphan.
    try {
      await registry.upsert(
        ProcessLease(
          id: leaseId,
          pid: process.pid,
          kind: kind,
          scope: LeaseScope.fromLabel(request.component.lifecycle.scope.name),
          ownership: LeaseOwnership.owned,
          ownerCmd: 'resource_composition:${request.component.id}',
          startedAt: DateTime.now().toUtc(),
          stopHint: LeaseStopHint(tool: 'kill', args: ['${process.pid}']),
          identity: {processLeasePidTokenKey: ?identityToken},
        ),
      );
    } on Object catch (error) {
      // Persistence is part of acquiring a durable managed component. A
      // failed acquisition must not abandon its already-spawned process.
      String cleanup;
      try {
        cleanup = await _killSpawned(process, identityToken)
            ? 'owned process teardown verified'
            : 'owned process teardown unverified; process may remain alive';
      } on Object catch (cleanupError) {
        cleanup = 'owned process teardown unverified: $cleanupError';
      }
      throw StateError(
        'lease persistence failed for "$leaseId" (pid ${process.pid}): '
        '$error; $cleanup',
      );
    }

    final stdout = _LineBuffer();
    final stderr = _BoundedLog();
    final earlyExit = Completer<int>();
    unawaited(
      process.exitCode.then(
        earlyExit.complete,
        onError: (Object _) => earlyExit.complete(-1),
      ),
    );
    final pumps = _pump(process, request.log, stdout, stderr);

    var serviceReady = false;
    Map<String, Object?> resolved;
    try {
      final readiness = request.component.readiness;
      resolved = readiness == null
          ? const <String, Object?>{}
          : await _resolve(
              readiness,
              stdout,
              stderr,
              earlyExit,
              request.cancellation,
            );
      if (runToExit) {
        final code = await Future.any<int?>([
          earlyExit.future,
          request.cancellation.future.then((_) => null),
        ]);
        if (code == null) throw const StartCancelled('leased process job');
        if (code != 0) throw StateError('job exited with code $code');
        await _deleteMatchingLease(process.pid, identityToken);
      } else {
        serviceReady = true;
      }
    } on StartCancelled {
      if (await _killSpawned(process, identityToken)) {
        await _deleteMatchingLease(process.pid, identityToken);
      }
      rethrow;
    } on Object catch (error) {
      if (await _killSpawned(process, identityToken)) {
        await _deleteMatchingLease(process.pid, identityToken);
      }
      throw StateError(
        'start of "$leaseId" failed before ready: $error\n'
        'stderr tail:\n${stderr.text}',
      );
    } finally {
      Future<void> closePumps() async {
        for (final sub in pumps) {
          await sub.cancel();
        }
        await stdout.close();
      }

      if (serviceReady) {
        // Readiness ends startup, not the lifetime of a service's pipes.
        unawaited(earlyExit.future.then((_) => closePumps()));
      } else {
        await closePumps();
      }
    }

    return StartReport(
      ref: ResourceRef(
        componentId: request.component.id,
        handle: leaseId,
        pid: process.pid,
        identityToken: identityToken,
      ),
      outputs: ResolvedOutputs(resolved),
    );
  }

  @override
  Future<Observation> inspect(ResourceRef ref) async {
    if (ref.pid == null) {
      return const Observation(
        state: ResourceState.unknown,
        cause: TerminalCause.unknown,
        message: 'no pid recorded',
      );
    }
    try {
      if (!await liveness.isAlive(ref.pid!)) {
        return const Observation(
          state: ResourceState.stopped,
          cause: TerminalCause.unknown,
        );
      }
      final identity = await verifyKillIdentity(
        liveness,
        ref.pid!,
        ref.identityToken,
      );
      return switch (identity) {
        KillIdentity.verified => const Observation(state: ResourceState.ready),
        KillIdentity.recycled => const Observation(
          state: ResourceState.stopped,
          cause: TerminalCause.unknown,
          message: 'recorded process identity is stale',
        ),
        KillIdentity.unknown => const Observation(
          state: ResourceState.unknown,
          cause: TerminalCause.unknown,
          message: 'live PID identity is unverified',
        ),
      };
    } on Object {
      return const Observation(
        state: ResourceState.unknown,
        cause: TerminalCause.unknown,
      );
    }
  }

  @override
  Future<StopReport> stop(ResourceRef ref, {required Duration grace}) async {
    final lease = await registry.read(leaseId);
    if (lease != null && lease.ownership == LeaseOwnership.borrowed) {
      // Teardown stops only owned leases (ADR-0018 §3).
      return const StopReport(
        disposition: StopDisposition.refused,
        message: 'lease is borrowed; only the owning terminal may stop it',
      );
    }
    if (ref.pid == null) {
      return const StopReport(
        disposition: StopDisposition.unknown,
        cause: TerminalCause.unknown,
        message: 'no pid recorded; report-never-guess',
      );
    }
    final result = await stopProcessTree(
      probe: treeProbe,
      liveness: liveness,
      rootPid: ref.pid!,
      rootIdentityToken: ref.identityToken,
      grace: grace,
    );
    if (result.stopped) {
      await _deleteMatchingLease(ref.pid!, ref.identityToken);
    }
    return StopReport(
      disposition: result.stopped
          ? StopDisposition.stopped
          : StopDisposition.unknown,
      cause: TerminalCause.exited,
      message: result.stopped
          ? null
          : 'survivors after the ladder: ${result.survivors}; '
                '${result.notes.join('; ')}',
    );
  }

  @override
  Future<Observation> reconcile(ResourceRef ref) async {
    // Report-only: reconciliation observes, it never signals (ADR-0018 §5).
    if (ref.pid != null) {
      try {
        if (!await liveness.isAlive(ref.pid!)) {
          return const Observation(
            state: ResourceState.stopped,
            cause: TerminalCause.unknown,
          );
        }
      } on Object {
        return const Observation(
          state: ResourceState.unknown,
          cause: TerminalCause.unknown,
        );
      }
    }
    final lease = await registry.read(leaseId);
    if (lease == null) {
      return const Observation(
        state: ResourceState.unknown,
        cause: TerminalCause.unknown,
        message: 'no lease record; a live pid alone is not identity',
      );
    }
    final verdict = await registry.checkLiveness(lease);
    return switch (verdict) {
      LeaseLiveness.live => const Observation(state: ResourceState.ready),
      LeaseLiveness.deadPid || LeaseLiveness.reusedPid => Observation(
        state: ResourceState.stopped,
        cause: TerminalCause.unknown,
        message: 'lease verdict ${verdict.name}; record is stale',
      ),
      LeaseLiveness.unknown => const Observation(
        state: ResourceState.unknown,
        cause: TerminalCause.unknown,
        message: 'identity could not be verified; retained, never signaled',
      ),
    };
  }

  Future<bool> _killSpawned(Process process, String? token) async {
    if (token == null) {
      // Never signal a live root without its spawn identity. A dead root
      // and empty observed subtree need no signals; an unavailable tree
      // is not proof of teardown.
      final tree = await treeProbe.enumerate(process.pid);
      return tree != null &&
          tree.descendants().isEmpty &&
          !await liveness.isAlive(process.pid);
    }
    final result = await stopProcessTree(
      probe: treeProbe,
      liveness: liveness,
      rootPid: process.pid,
      rootIdentityToken: token,
    );
    return result.stopped;
  }

  Future<void> _deleteMatchingLease(int pid, String? token) async {
    final current = await registry.read(leaseId);
    if (current != null &&
        current.ownership == LeaseOwnership.owned &&
        current.pid == pid &&
        current.identity[processLeasePidTokenKey] == token) {
      await registry.delete(leaseId);
    }
  }

  /// Resolves the component's declared readiness (provider-owned probe
  /// mechanics) into typed outputs, honoring cancellation instead of
  /// abandoning the child.
  Future<Map<String, Object?>> _resolve(
    Readiness readiness,
    _LineBuffer stdout,
    _BoundedLog stderr,
    Completer<int> earlyExit,
    Cancellation cancellation,
  ) async {
    switch (readiness) {
      case final HandshakeLine handshake:
        final line = await _waitForLine(
          stdout,
          stderr,
          earlyExit,
          cancellation,
          handshake.pattern,
        );
        return handshake.parse?.call(line) ?? const <String, Object?>{};
      case final LogPattern pattern:
        await _waitForLine(
          stdout,
          stderr,
          earlyExit,
          cancellation,
          pattern.pattern,
        );
        return const <String, Object?>{};
      case final FilePresent file:
        await _waitFor(
          earlyExit,
          cancellation,
          stderr,
          until: () async => File(file.path).existsSync(),
          describe: 'file ${file.path}',
        );
        return const <String, Object?>{};
      case final TcpConnect tcp:
        await _waitFor(
          earlyExit,
          cancellation,
          stderr,
          until: () async {
            try {
              final socket = await Socket.connect(
                tcp.host,
                tcp.port,
                timeout: const Duration(milliseconds: 300),
              );
              socket.destroy();
              return true;
            } on Object {
              return false;
            }
          },
          describe: 'tcp ${tcp.host}:${tcp.port}',
        );
        return const <String, Object?>{};
      case final ArtifactFresh artifact:
        // Presence is the start-time probe; source-vs-artifact staleness is
        // an observe/apply concern (rebuild), not a hang on spawn.
        await _waitFor(
          earlyExit,
          cancellation,
          stderr,
          until: () async => File(artifact.artifactPath).existsSync(),
          describe: 'artifact ${artifact.artifactPath}',
        );
        return const <String, Object?>{};
      case ReadinessAll(:final conditions):
        final merged = <String, Object?>{};
        for (final condition in conditions) {
          merged.addAll(
            await _resolve(condition, stdout, stderr, earlyExit, cancellation),
          );
        }
        return merged;
    }
  }

  Future<String> _waitForLine(
    _LineBuffer buffer,
    _BoundedLog stderr,
    Completer<int> earlyExit,
    Cancellation cancellation,
    Pattern? pattern,
  ) async {
    while (true) {
      final line = buffer.next(pattern);
      if (line != null) return line;
      final result = await Future.any<Object?>([
        buffer.stream.first,
        earlyExit.future,
        cancellation.future,
      ]);
      if (result is int) {
        throw StateError(
          'process exited (code $result) before the readiness line; '
          'stderr tail:\n${stderr.text}',
        );
      }
      if (result == null && cancellation.isCancelled) {
        throw const StartCancelled('leased process');
      }
    }
  }

  Future<void> _waitFor(
    Completer<int> earlyExit,
    Cancellation cancellation,
    _BoundedLog stderr, {
    required Future<bool> Function() until,
    required String describe,
  }) async {
    while (true) {
      if (await until()) return;
      final result = await Future.any<Object?>([
        Future<void>.delayed(const Duration(milliseconds: 100))
            .then((_) => 'tick'),
        earlyExit.future,
        cancellation.future,
      ]);
      if (result is int) {
        throw StateError(
          'process exited (code $result) before $describe was satisfied; '
          'stderr tail:\n${stderr.text}',
        );
      }
      if (result == null && cancellation.isCancelled) {
        throw StartCancelled('leased process waiting for $describe');
      }
    }
  }
}

List<StreamSubscription<String>> _pump(
  Process process,
  LogTap? log,
  _LineBuffer stdout,
  _BoundedLog stderr,
) {
  // Startup failures/jobs close these; ready services drain until exit.
  // ignore: cancel_subscriptions
  final stdoutSub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        stdout.add(line);
        log?.add(line);
      });
  // ignore: cancel_subscriptions
  final stderrSub = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        stderr.add(line);
        log?.add(line);
      });
  return <StreamSubscription<String>>[stdoutSub, stderrSub];
}

/// Lines with replay: `next` checks everything buffered so far (so a match
/// that landed between waits is not lost), and [stream] carries live lines.
final class _LineBuffer {
  final _buffer = <String>[];
  final _stream = StreamController<String>.broadcast();

  Stream<String> get stream => _stream.stream;
  Future<void> close() => _stream.close();

  void add(String line) {
    _buffer.add(line);
    if (_buffer.length > 4000) _buffer.removeAt(0);
    _stream.add(line);
  }

  /// The first buffered line matching [pattern] (null when none yet).
  String? next(Pattern? pattern) {
    if (pattern == null) {
      return _buffer.isEmpty ? null : _buffer.removeAt(0);
    }
    for (var index = 0; index < _buffer.length; index++) {
      if (pattern.allMatches(_buffer[index]).isNotEmpty) {
        return _buffer.removeAt(index);
      }
    }
    return null;
  }
}

final class _BoundedLog {
  final _bytes = BytesBuilder(copy: false);
  var _size = 0;

  void add(String line) {
    if (_size >= 16 * 1024) return;
    final chunk = utf8.encode('$line\n');
    final room = 16 * 1024 - _size;
    if (chunk.length > room) {
      _bytes.add(chunk.sublist(0, room));
      _size = 16 * 1024;
      return;
    }
    _bytes.add(chunk);
    _size += chunk.length;
  }

  String get text => utf8.decode(_bytes.takeBytes(), allowMalformed: true);
}
