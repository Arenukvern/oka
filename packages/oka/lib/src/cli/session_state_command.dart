import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_android/oka_android.dart';
import 'package:oka_web/oka_web.dart';

import 'session_state_entrypoint.dart';

/// `oka session-state` — inspect and conservatively reconcile managed state.
///
/// Reconciliation and explicit close are dry runs unless `--apply` is given.
final class SessionStateCommand {
  SessionStateCommand({
    SessionStateRegistry? registry,
    List<SessionStateWorkflow<dynamic>>? workflows,
    ProcessLiveness? liveness,
    void Function(String)? output,
    void Function(String)? errorOutput,
    void Function(int)? setExitCode,
  }) : _registry = registry ?? SessionStateRegistry.forCurrentUser(),
       _workflows = List.unmodifiable(
         workflows ?? [chromeProfileStateWorkflow, androidAvdStateWorkflow],
       ),
       _liveness = liveness ?? const HostProcessLiveness(),
       _useProjectEntrypoint =
           registry == null && workflows == null && liveness == null,
       _output = output ?? stdout.writeln,
       _errorOutput = errorOutput ?? stderr.writeln,
       _setExitCode = setExitCode ?? _setProcessExitCode;

  final SessionStateRegistry _registry;
  final List<SessionStateWorkflow<dynamic>> _workflows;
  final ProcessLiveness _liveness;
  final bool _useProjectEntrypoint;
  final void Function(String) _output;
  final void Function(String) _errorOutput;
  final void Function(int) _setExitCode;

  static void _setProcessExitCode(final int value) => exitCode = value;

  Future<void> run(final List<String> args) async {
    final parser = ArgParser()
      ..addFlag('json', negatable: false, help: 'Emit one JSON report.')
      ..addFlag('apply', negatable: false, help: 'Apply eligible cleanup.')
      ..addFlag('verbose', negatable: false, help: 'Include full findings.')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');

    late final ArgResults results;
    try {
      results = parser.parse(args);
    } on ArgParserException catch (error) {
      _errorOutput('Invalid session-state arguments: ${error.message}');
      _errorOutput(parser.usage);
      _setExitCode(1);
      return;
    }
    if (results['help'] as bool) {
      _output(
        'oka session-state [list|inspect <id>|resume <id>|reconcile|close '
        '<id>|forget <id>] [--json] [--verbose] [--apply]\n'
        'resume is an explicit action and does not use --apply.\n'
        '${parser.usage}',
      );
      return;
    }

    final positional = results.rest;
    final command = positional.isEmpty ? 'list' : positional.first;
    final json = results['json'] as bool;
    final apply = results['apply'] as bool;
    final verbose = results['verbose'] as bool;

    if (command == 'resume') {
      if (positional.length != 2 || apply || verbose) {
        _errorOutput('Usage: oka session-state resume <id> [--json]');
        _setExitCode(1);
        return;
      }
      if (_useProjectEntrypoint) {
        final delegated = await _delegate(
          command,
          positional,
          apply: false,
          json: json,
          verbose: false,
        );
        if (delegated) return;
      }
      await _resume(positional[1], json: json);
      return;
    }

    if (command == 'list') {
      if (positional.length > 1 || apply) {
        _errorOutput('Usage: oka session-state list [--json]');
        _setExitCode(1);
        return;
      }
      await _list(json: json);
      return;
    }

    if (command != 'inspect' &&
        command != 'reconcile' &&
        command != 'close' &&
        command != 'forget') {
      _errorOutput(
        'Unknown session-state command "$command". Use list, inspect <id>, '
        'reconcile, resume <id>, close <id>, or forget <id>.',
      );
      _setExitCode(1);
      return;
    }
    if (command == 'inspect' && (positional.length != 2 || apply)) {
      _errorOutput(
        'Usage: oka session-state inspect <id> [--json] [--verbose]',
      );
      _setExitCode(1);
      return;
    }
    if (command == 'reconcile' && positional.length != 1) {
      _errorOutput('Usage: oka session-state reconcile [--json] [--apply]');
      _setExitCode(1);
      return;
    }
    if (command == 'close' && positional.length != 2) {
      _errorOutput(
        'Usage: oka session-state close <id> [--json] [--verbose] [--apply]',
      );
      _setExitCode(1);
      return;
    }
    if (command == 'forget' && positional.length != 2) {
      _errorOutput(
        'Usage: oka session-state forget <id> [--json] [--verbose] [--apply]',
      );
      _setExitCode(1);
      return;
    }

    if (command != 'list' && _useProjectEntrypoint) {
      final delegated = await _delegate(
        command,
        positional,
        apply: apply,
        json: json,
        verbose: verbose,
      );
      if (delegated) return;
    }

    final SessionStateReconcileReport report;
    try {
      final reconciler = SessionStateReconciler(
        registry: _registry,
        workflows: _workflows,
        liveness: _liveness,
      );
      report = switch (command) {
        'inspect' => await reconciler.inspectLease(leaseId: positional[1]),
        'close' => await reconciler.close(leaseId: positional[1], apply: apply),
        'forget' => await reconciler.forget(
          leaseId: positional[1],
          apply: apply,
        ),
        _ => await reconciler.reconcile(apply: apply),
      };
    } on Object catch (error) {
      _errorOutput('Session-state $command failed: $error');
      _setExitCode(1);
      return;
    }
    final selected = report.entries;
    final missingLease =
        (command == 'inspect' || command == 'close' || command == 'forget') &&
        selected.isEmpty;
    if (command == 'inspect' && selected.isEmpty) {
      _errorOutput('No session-state lease found with id "${positional[1]}".');
      _setExitCode(1);
    }
    if ((command == 'close' || command == 'forget') && selected.isEmpty) {
      _errorOutput('No session-state lease found with id "${positional[1]}".');
      _setExitCode(1);
    }
    final result = _SessionStateCommandReport(
      report: report,
      entries: selected,
    );
    final showDeletionSafetyNote =
        apply && (command == 'close' || command == 'reconcile');
    if (json) {
      _writeJson(
        switch (command) {
          'inspect' => 'session-state.inspect',
          'close' => 'session-state.close',
          'forget' => 'session-state.forget',
          _ => 'session-state.reconcile',
        },
        {
          ...result.toJson(),
          if (showDeletionSafetyNote)
            'safety_notes': [
              'Process identity and provider markers do not prove that every detached child or concurrent opener is absent; path-based checks are not a security boundary against same-user filesystem races.',
            ],
        },
      );
    } else if (!missingLease || report.issues.isNotEmpty) {
      _printReport(
        result,
        verbose: verbose,
        requireCompletedAction: command == 'close' || command == 'forget',
        showDeletionSafetyNote: showDeletionSafetyNote,
        operation: switch (command) {
          'inspect' => 'inspection',
          'close' => 'close',
          'forget' => 'forget',
          _ => 'reconciliation',
        },
      );
    }
    if (report.issues.isNotEmpty ||
        selected.any(
          (final entry) => entry.disposition == SessionStateDisposition.error,
        ) ||
        (apply &&
            (command == 'close' || command == 'forget') &&
            selected.any(
              (final entry) =>
                  entry.disposition == SessionStateDisposition.retained ||
                  entry.disposition == SessionStateDisposition.eligible,
            ))) {
      _setExitCode(1);
    }
  }

  Future<bool> _delegate(
    final String command,
    final List<String> positional, {
    required final bool apply,
    required final bool json,
    required final bool verbose,
  }) async {
    final Map<String, Object?>? result;
    try {
      result = await runProjectSessionState(
        projectPath: Directory.current.path,
        request: {
          'operation': command,
          if (command != 'reconcile') 'lease_id': positional[1],
          if (command == 'close' ||
              command == 'forget' ||
              command == 'reconcile')
            'apply': apply,
        },
      );
    } on Object catch (error) {
      if (command == 'resume' && json) {
        _writeJson('session-state.resume', {
          'lease_id': positional[1],
          'status': 'error',
          'error': error.toString(),
        });
      } else {
        _errorOutput('Session-state $command failed: $error');
      }
      _setExitCode(1);
      return true;
    }
    if (result == null) return false;

    if (command == 'resume') {
      final lease = result['lease'];
      if (lease is! Map) {
        _errorOutput('Session-state resume failed: invalid protocol result.');
        _setExitCode(1);
        return true;
      }
      final leaseMap = lease.cast<String, Object?>();
      final params = {
        'lease_id': leaseMap['id'],
        'workflow_id': leaseMap['workflow_id'],
        'workflow_version': leaseMap['workflow_version'],
        'phase': leaseMap['phase'],
        'status': result['status'],
      };
      if (json) {
        _writeJson('session-state.resume', params);
      } else {
        _output(
          'Resumed session-state "${params['lease_id']}" '
          '(${params['workflow_id']}@${params['workflow_version']}); '
          'phase is ${params['phase']}.',
        );
      }
      return true;
    }

    final entries = (result['entries'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((final entry) => entry.cast<String, Object?>())
        .toList();
    final issues = (result['issues'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((final issue) => issue.cast<String, Object?>())
        .toList();
    final missingLease =
        (command == 'inspect' || command == 'close' || command == 'forget') &&
        entries.isEmpty;
    if (missingLease) {
      _errorOutput('No session-state lease found with id "${positional[1]}".');
      _setExitCode(1);
    }
    final showSafetyNote =
        apply && (command == 'close' || command == 'reconcile');
    if (json) {
      _writeJson(
        switch (command) {
          'inspect' => 'session-state.inspect',
          'close' => 'session-state.close',
          'forget' => 'session-state.forget',
          _ => 'session-state.reconcile',
        },
        {
          ...result,
          if (showSafetyNote)
            'safety_notes': [
              'Process identity and provider markers do not prove that every detached child or concurrent opener is absent; path-based checks are not a security boundary against same-user filesystem races.',
            ],
        },
      );
    } else if (!missingLease || issues.isNotEmpty) {
      _printDelegatedReport(
        result,
        entries,
        issues,
        verbose: verbose,
        showDeletionSafetyNote: showSafetyNote,
        operation: switch (command) {
          'inspect' => 'inspection',
          'close' => 'close',
          'forget' => 'forget',
          _ => 'reconciliation',
        },
        requireCompletedAction: command == 'close' || command == 'forget',
      );
    }
    if (issues.isNotEmpty ||
        entries.any((final entry) => entry['disposition'] == 'error') ||
        (apply &&
            (command == 'close' || command == 'forget') &&
            entries.any(
              (final entry) =>
                  entry['disposition'] == 'retained' ||
                  entry['disposition'] == 'eligible',
            ))) {
      _setExitCode(1);
    }
    return true;
  }

  void _printDelegatedReport(
    final Map<String, Object?> report,
    final List<Map<String, Object?>> entries,
    final List<Map<String, Object?>> issues, {
    required final bool verbose,
    required final bool showDeletionSafetyNote,
    required final String operation,
    required final bool requireCompletedAction,
  }) {
    final summary = (report['summary'] as Map?)?.cast<String, Object?>() ?? {};
    _output(
      'Session-state $operation '
      '${report['applied'] == true ? 'applied' : 'preview'}: '
      '${entries.length} lease(s), ${summary['eligible'] ?? 0} eligible, '
      '${summary['forgotten'] ?? 0} forgotten, '
      '${summary['retained'] ?? 0} retained, ${issues.length} registry issue(s).',
    );
    if (showDeletionSafetyNote) {
      _output(
        'Safety limit: process identity and provider markers do not prove that '
        'every detached child or concurrent opener is absent, and path-based '
        'checks are not a security boundary against same-user filesystem races.',
      );
    }
    for (final entry in entries) {
      final lease = (entry['lease'] as Map?)?.cast<String, Object?>() ?? {};
      _output(
        '${lease['id']}  ${lease['workflow_id']}@${lease['workflow_version']}  '
        '${lease['retention']}/${lease['ownership']}  '
        '${entry['disposition']}: ${entry['reason']}',
      );
      if (verbose) {
        for (final finding in (entry['findings'] as List? ?? const [])) {
          if (finding is! Map) continue;
          final item = finding.cast<String, Object?>();
          _output(
            '  ${item['use']}: ${item['inspector_id']}: ${item['reason']}',
          );
          final details = item['details'];
          if (details is Map) {
            for (final detail in details.entries) {
              _output('    ${detail.key}: ${detail.value}');
            }
          }
        }
      }
    }
    for (final issue in issues) {
      _errorOutput('Registry issue at ${issue['path']}: ${issue['message']}');
    }
    if (report['applied'] != true &&
        entries.any((final entry) => entry['disposition'] == 'eligible')) {
      _output(
        'No changes made. Re-run with --apply to apply eligible actions.',
      );
    }
    if (report['applied'] == true &&
        requireCompletedAction &&
        entries.any(
          (final entry) =>
              entry['disposition'] == 'retained' ||
              entry['disposition'] == 'eligible',
        )) {
      _output(
        'Apply was requested, but one or more actions were retained or '
        'not completed. Review the disposition and reason above.',
      );
    }
  }

  Future<void> _resume(final String leaseId, {required final bool json}) async {
    try {
      final lease = await _registry.read(leaseId);
      if (lease == null) {
        throw SessionStateRegistryException(
          'No session-state lease found with id "$leaseId".',
        );
      }
      final matching = _workflows.where(
        (final workflow) =>
            workflow.id == lease.workflowId &&
            workflow.version == lease.workflowVersion,
      );
      if (matching.length != 1) {
        throw SessionStateRegistryException(
          'No unique composed workflow matches '
          '${lease.workflowId}@${lease.workflowVersion}; resume is unavailable.',
        );
      }
      final resumed = await SessionStateManager(
        registry: _registry,
        liveness: _liveness,
      ).resume(matching.single, leaseId);
      final params = {
        'lease_id': resumed.id,
        'workflow_id': resumed.workflowId,
        'workflow_version': resumed.workflowVersion,
        'phase': resumed.phase.label,
        'status': 'ready',
      };
      if (json) {
        _writeJson('session-state.resume', params);
      } else {
        _output(
          'Resumed session-state "${resumed.id}" '
          '(${resumed.workflowId}@${resumed.workflowVersion}); phase is ready.',
        );
      }
    } on Object catch (error) {
      if (json) {
        _writeJson('session-state.resume', {
          'lease_id': leaseId,
          'status': 'error',
          'error': error.toString(),
        });
      } else {
        _errorOutput('Session-state resume failed: $error');
      }
      _setExitCode(1);
    }
  }

  Future<void> _list({required final bool json}) async {
    final SessionStateRegistrySnapshot snapshot;
    try {
      snapshot = await _registry.inspect();
    } on Object catch (error) {
      _errorOutput('Could not inspect session-state registry: $error');
      _setExitCode(1);
      return;
    }
    if (snapshot.issues.isNotEmpty) _setExitCode(1);
    final value = {
      'schema_version': 'oka.session-state.inventory.v1',
      'registry': _registry.directory.path,
      'summary': {
        'leases': snapshot.leases.length,
        'registry_issues': snapshot.issues.length,
      },
      'leases': snapshot.leases.map((final lease) => lease.toJson()).toList(),
      'issues': snapshot.issues.map((final issue) => issue.toJson()).toList(),
    };
    if (json) {
      _writeJson('session-state.inventory', value);
      return;
    }
    _output('Session-state registry: ${_registry.directory.path}');
    if (snapshot.leases.isEmpty && snapshot.issues.isEmpty) {
      _output('No managed session-state resources are recorded.');
      return;
    }
    for (final lease in snapshot.leases) {
      _output(
        '${lease.id}  ${lease.workflowId}@${lease.workflowVersion}  '
        '${lease.retention.label}/${lease.ownership.label}  '
        '${lease.phase.label}  ${lease.rootPath}/${lease.relativePath}',
      );
    }
    for (final issue in snapshot.issues) {
      _errorOutput('Registry issue at ${issue.path}: ${issue.message}');
    }
  }

  void _printReport(
    final _SessionStateCommandReport result, {
    required final bool verbose,
    required final bool requireCompletedAction,
    required final bool showDeletionSafetyNote,
    required final String operation,
  }) {
    final report = result.report;
    _output(
      'Session-state $operation ${report.applied ? 'applied' : 'preview'}: '
      '${result.entries.length} lease(s), '
      '${result.entries.where((final e) => e.disposition == SessionStateDisposition.eligible).length} '
      'eligible, ${report.forgottenCount} forgotten, '
      '${result.entries.where((final e) => e.disposition == SessionStateDisposition.retained).length} '
      'retained, ${report.issues.length} registry issue(s).',
    );
    if (showDeletionSafetyNote) {
      _output(
        'Safety limit: process identity and provider markers do not prove that '
        'every detached child or concurrent opener is absent, and path-based '
        'checks are not a security boundary against same-user filesystem races.',
      );
    }
    for (final entry in result.entries) {
      _output(entry.toLine());
      if (verbose) {
        for (final finding in entry.findings) {
          _output(
            '  ${finding.use.name}: ${finding.inspectorId}: '
            '${finding.reason}',
          );
          for (final detail in finding.details.entries) {
            _output('    ${detail.key}: ${detail.value}');
          }
        }
      }
    }
    for (final issue in report.issues) {
      _errorOutput('Registry issue at ${issue.path}: ${issue.message}');
    }
    if (!report.applied &&
        result.entries.any(
          (final entry) =>
              entry.disposition == SessionStateDisposition.eligible,
        )) {
      _output(
        'No changes made. Re-run with --apply to apply eligible actions.',
      );
    }
    if (report.applied &&
        requireCompletedAction &&
        result.entries.any(
          (final entry) =>
              entry.disposition == SessionStateDisposition.retained ||
              entry.disposition == SessionStateDisposition.eligible,
        )) {
      _output(
        'Apply was requested, but one or more actions were retained or '
        'not completed. Review the disposition and reason above.',
      );
    }
  }

  void _writeJson(final String event, final Map<String, Object?> params) {
    _output(
      jsonEncode({
        'scope': 'session-state',
        'event': event,
        'params': params,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }
}

final class _SessionStateCommandReport {
  const _SessionStateCommandReport({
    required this.report,
    required this.entries,
  });

  final SessionStateReconcileReport report;
  final List<SessionStateReconcileEntry> entries;

  Map<String, Object?> toJson() => {
    ...report.toJson(),
    'entries': entries.map((final entry) => entry.toJson()).toList(),
  };
}
