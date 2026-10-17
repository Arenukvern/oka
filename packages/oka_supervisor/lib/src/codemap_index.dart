/// Native Codemap index lifecycle composition (ADR-0045).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:resource_composition/resource_composition.dart';

import 'spec.dart';

/// Explicit declaration; scope remains Codemap-owned JSON, never reconstructed
/// from a different watcher filter in Oka.
final class CodemapIndexRecipe {
  CodemapIndexRecipe({
    required this.executable,
    required final String projectRoot,
    final String? receiptPath,
    this.scope,
    this.reconcilePeriod = const Duration(seconds: 5),
    this.pollPeriod = const Duration(milliseconds: 200),
    this.readinessBudget = const Duration(seconds: 30),
    this.policy = const SupervisionPolicy(),
    this.id = 'codemap-index',
  }) : projectRoot = Directory(projectRoot).resolveSymbolicLinksSync(),
       receiptPath = p.absolute(
         receiptPath ?? p.join(projectRoot, '.codemap', 'index-watch.json'),
       ) {
    if (reconcilePeriod.inMilliseconds <= 0 || pollPeriod.inMilliseconds <= 0) {
      throw ArgumentError('worker periods must be positive');
    }
  }

  final String executable;
  final String projectRoot;
  final String receiptPath;
  final Map<String, Object?>? scope;
  final Duration reconcilePeriod;
  final Duration pollPeriod;
  final Duration readinessBudget;
  final SupervisionPolicy policy;
  final String id;

  /// Resolves the declared executable on each pass. No mtime-only cache:
  /// an atomic replacement or same-size rewrite must change desired identity.
  String get executablePath {
    if (p.isAbsolute(executable) ||
        executable.contains('/') ||
        executable.contains(r'\')) {
      // Teardown must remain possible even when the deployment disappeared.
      // Desired-state hashing below still refuses missing executable bytes.
      return p.absolute(executable);
    }
    final candidates = [
      for (final directory in (Platform.environment['PATH'] ?? '').split(
        Platform.isWindows ? ';' : ':',
      ))
        p.absolute(directory, executable),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
      if (Platform.isWindows && File('$candidate.exe').existsSync()) {
        return '$candidate.exe';
      }
    }
    throw StateError('native Codemap executable not found: $executable');
  }

  ProcessCommand get command => ProcessCommand(executablePath, [
    '--index-watch-worker',
    '--root',
    projectRoot,
    '--receipt',
    receiptPath,
    '--reconcile-ms',
    '${reconcilePeriod.inMilliseconds}',
    '--poll-ms',
    '${pollPeriod.inMilliseconds}',
    if (scope != null) ...['--scope-json', jsonEncode(scope)],
  ]);

  ComponentSpec get spec {
    final launch = command;
    final resolved = File(launch.executable).resolveSymbolicLinksSync();
    final fingerprint = sha256.convert(File(resolved).readAsBytesSync());
    return ComponentSpec(
      id: id,
      providerName: 'codemap-index',
      readiness: HandshakeLine(
        pattern: 'codemap-index-watch-ready',
        budget: readinessBudget,
      ),
      policy: policy,
      env: {
        'command': jsonEncode([launch.executable, ...launch.arguments]),
        'resolved_executable': resolved,
        'executable_sha256': fingerprint.toString(),
      },
    );
  }

  DesiredState get desired => DesiredState(specs: [spec]);

  CodemapIndexProvider provider({final ProcessLeaseRegistry? registry}) =>
      CodemapIndexProvider(
        process: LeasedProcessProvider(
          leaseId: id,
          command: command,
          registry: registry ?? ProcessLeaseRegistry.forProject(projectRoot),
          kind: 'codemap-index',
        ),
        projectRoot: projectRoot,
        receiptPath: receiptPath,
        maxReceiptAge: reconcilePeriod * 3 + const Duration(seconds: 30),
      );
}

/// Structured health is independent of process liveness. Unknown evidence
/// never promotes a process to dead or grants restart/signal authority.
final class CodemapIndexHealth {
  const CodemapIndexHealth(this.state, this.message, [this.receipt]);
  final String state;
  final String message;
  final Map<String, Object?>? receipt;
  bool get current => state == 'ready';

  // Receipt parsing is a fallible observation, not object construction.
  // ignore: prefer_constructors_over_static_methods
  static CodemapIndexHealth read({
    required final String receiptPath,
    required final String projectRoot,
    required final int? pid,
    required final DateTime now,
    required final Duration maxAge,
  }) {
    try {
      final json = jsonDecode(File(receiptPath).readAsStringSync());
      if (json is! Map<String, dynamic> ||
          json['schema'] != 'codemap.index-watch.v1') {
        return const CodemapIndexHealth('unknown', 'invalid receipt schema');
      }
      if (pid == null || json['pid'] != pid || json['root'] != projectRoot) {
        return const CodemapIndexHealth(
          'unknown',
          'receipt root/PID does not match leased worker',
        );
      }
      final updated = DateTime.tryParse('${json['updated_at']}');
      if (updated == null ||
          now.difference(updated) > maxAge ||
          updated.isAfter(now.add(const Duration(seconds: 5)))) {
        return const CodemapIndexHealth(
          'unknown',
          'receipt heartbeat missing, stale or in the future',
        );
      }
      final state = json['state'];
      if (!['ready', 'pending', 'blocked'].contains(state)) {
        return const CodemapIndexHealth('unknown', 'invalid semantic state');
      }
      if (state == 'ready' &&
          (json['observed_revision'] is! String ||
              (json['observed_revision'] as String).isEmpty ||
              json['observed_revision'] != json['published_revision'] ||
              json['dirty_count'] != 0)) {
        return const CodemapIndexHealth(
          'unknown',
          'inconsistent ready receipt',
        );
      }
      return CodemapIndexHealth(
        state as String,
        'index $state; observed=${json['observed_revision']}; '
        'published=${json['published_revision']}; '
        'dirty=${json['dirty_count']}; '
        'continuity=${json['watcher_continuity']}; '
        'blocker=${json['blocker']}',
        json,
      );
    } on Object catch (error) {
      return CodemapIndexHealth('unknown', 'receipt unreadable: $error');
    }
  }
}

final class CodemapIndexProvider implements ResourceProvider {
  CodemapIndexProvider({
    required this.process,
    required this.projectRoot,
    required this.receiptPath,
    this.maxReceiptAge = const Duration(seconds: 45),
    final DateTime Function()? clock,
  }) : clock = clock ?? (() => DateTime.now().toUtc());

  final LeasedProcessProvider process;
  final String projectRoot;
  final String receiptPath;
  final Duration maxReceiptAge;
  final DateTime Function() clock;

  CodemapIndexHealth health(final ResourceRef ref) => CodemapIndexHealth.read(
    receiptPath: receiptPath,
    projectRoot: projectRoot,
    pid: ref.pid,
    now: clock(),
    maxAge: maxReceiptAge,
  );

  @override
  ProviderCapabilities get capabilities => process.capabilities;
  @override
  Future<StartReport> start(final StartRequest request) =>
      process.start(request);
  @override
  Future<StopReport> stop(
    final ResourceRef ref, {
    required final Duration grace,
  }) => process.stop(ref, grace: grace);
  @override
  Future<Observation> inspect(final ResourceRef ref) async {
    final live = await process.reconcile(ref);
    if (live.state != ResourceState.ready) return live;
    final index = health(ref);
    return Observation(
      state: switch (index.state) {
        'ready' => ResourceState.ready,
        'pending' || 'blocked' => ResourceState.starting,
        _ => ResourceState.unknown,
      },
      message: index.message,
    );
  }

  @override
  Future<Observation> reconcile(final ResourceRef ref) => inspect(ref);
}
