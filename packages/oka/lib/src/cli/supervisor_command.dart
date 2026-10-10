import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_core/oka_core.dart';
import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';

/// `oka supervisor` — the CLI seam for the declarative supervisor
/// (ADR-0040/0041): read one project's converged-so-far status, or apply
/// one crash-only converge pass from an authored plan document.
///
/// Status is records-only (read surface, ADR-0041); apply decodes the
/// plan, validates it against this CLI's provider seam, and hands the
/// pass to [Supervisor] — validation failures never contact a process.
final class SupervisorCommand {
  SupervisorCommand({
    final void Function(String)? output,
    final void Function(String)? errorOutput,
    final void Function(int)? setExitCode,
  }) : _output = output ?? stdout.writeln,
       _errorOutput = errorOutput ?? stderr.writeln,
       _setExitCode = setExitCode ?? _setProcessExitCode;

  final void Function(String) _output;
  final void Function(String) _errorOutput;
  final void Function(int) _setExitCode;

  static void _setProcessExitCode(final int value) => exitCode = value;

  Future<void> run(final List<String> args) async {
    if (args.isEmpty) {
      _output(_usage);
      return;
    }
    switch (args.first) {
      case 'status':
        await _status(args.skip(1).toList());
      case 'apply':
        await _apply(args.skip(1).toList());
      case 'check':
        await _check(args.skip(1).toList());
      case 'help' || '--help' || '-h':
        _output(_usage);
      default:
        _errorOutput(
          'Unknown supervisor command "${args.first}". '
          'Use status, apply or check.',
        );
        _setExitCode(1);
    }
  }

  Future<void> _status(final List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'project',
        help: 'Project root (defaults to the current directory).',
      )
      ..addOption(
        'registry-root',
        help: 'Supervisor registry root (defaults to ~/.oka/supervisor).',
      )
      ..addFlag('json', negatable: false, help: 'Emit one JSON document.')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');
    final results = _parse(parser, args);
    if (results == null) return;
    if (results['help'] as bool) {
      _output(
        'oka supervisor status [--project <dir>] [--registry-root <dir>] '
        '[--json]\n${parser.usage}',
      );
      return;
    }
    if (results.rest.isNotEmpty) {
      _errorOutput('Usage: oka supervisor status [--project <dir>] [--json]');
      _setExitCode(1);
      return;
    }

    final projectRoot =
        (results['project'] as String?) ?? Directory.current.path;
    final registry = _registry(results['registry-root'] as String?);
    final scope = registry.scopeFor(projectRoot);
    final snapshot = registry.snapshot(scope);
    final statuses = projectStatus(snapshot: snapshot);

    if (results['json'] as bool) {
      _output(
        statusJson(statuses: statuses, corruptPaths: snapshot.corruptPaths),
      );
      return;
    }
    if (statuses.isEmpty && snapshot.corruptPaths.isEmpty) {
      _output('no supervisor records for this project (scope $scope)');
      return;
    }
    _output(renderStatus(statuses));
    for (final path in snapshot.corruptPaths) {
      _output('corrupt record: $path');
    }
  }

  Future<void> _apply(final List<String> args) async {
    final parser = ArgParser()
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the plan without starting or stopping anything.',
      )
      ..addOption(
        'project',
        help: 'Project root (defaults to the current directory).',
      )
      ..addOption(
        'registry-root',
        help: 'Supervisor registry root (defaults to ~/.oka/supervisor).',
      )
      ..addOption(
        'evidence',
        help: 'Append lifecycle facts to this JSONL file.',
      )
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');
    final results = _parse(parser, args);
    if (results == null) return;
    if (results['help'] as bool) {
      _output(
        'oka supervisor apply <plan.json> [--dry-run] [--project <dir>] '
        '[--registry-root <dir>] [--evidence <file>]\n'
        'The process provider reads each spec env: "command" (executable) '
        'and optional "args" (space-split).\n'
        '${parser.usage}',
      );
      return;
    }
    if (results.rest.length != 1) {
      _errorOutput('Usage: oka supervisor apply <plan.json> [flags]');
      _setExitCode(1);
      return;
    }

    final planPath = results.rest.single;
    final String document;
    try {
      document = File(planPath).readAsStringSync();
    } on Object catch (error) {
      _errorOutput('Cannot read supervisor plan "$planPath": $error');
      _setExitCode(1);
      return;
    }
    final DesiredState desired;
    try {
      desired = const SpecCodec().decode(document);
    } on SpecFormatException catch (error) {
      _errorOutput('$error');
      _setExitCode(1);
      return;
    }
    final failure = _providerPreflight(desired);
    if (failure != null) {
      _errorOutput(failure);
      _setExitCode(1);
      return;
    }

    final projectRoot =
        (results['project'] as String?) ?? Directory.current.path;
    final registryRoot = results['registry-root'] as String?;
    final supervisor = Supervisor(
      projectRoot: projectRoot,
      registry: registryRoot == null
          ? null
          : MachineRegistry(root: registryRoot),
    );
    final processProvider = _ProcessProviderRouter(
      desired: desired,
      projectRoot: projectRoot,
    );

    final evidencePath = results['evidence'] as String?;
    final evidence = evidencePath == null
        ? null
        : JsonlEvidenceSink(evidencePath);
    final ConvergenceReport report;
    try {
      report = await supervisor.converge(
        desired: desired,
        factory: processProvider.factory,
        evidence: evidence,
        apply: !(results['dry-run'] as bool),
      );
    } on Object catch (error) {
      _errorOutput('Supervisor apply failed: $error');
      _setExitCode(1);
      return;
    } finally {
      await evidence?.close();
    }

    _output(report.describe());
    if (results['dry-run'] as bool && !report.invalid) {
      _output('Dry run: nothing was started. Re-run without --dry-run.');
    }
    if (!report.ok) _setExitCode(1);
  }

  /// Names the first declaration this CLI cannot run, or null when every
  /// spec resolves. Providers are named seams (ADR-0040): this CLI ships
  /// exactly one, and a process spec must say what to run.
  String? _providerPreflight(final DesiredState desired) {
    for (final spec in desired.specs) {
      if (spec.providerName != _processProviderName) {
        return 'unknown provider "${spec.providerName}"; '
            'this CLI provides: $_processProviderName';
      }
      if ((spec.env['command'] ?? '').isEmpty) {
        return 'spec "${spec.id}": provider "$_processProviderName" needs '
            'env["command"] (the executable to run)';
      }
    }
    return null;
  }

  /// The L2 drift gate (ADR-0041): a committed plan is compared against
  /// this machine's records — read-only, never converges. Fails on
  /// corrupt records, revision drift, absent services, or failed jobs;
  /// the CI hook for repo-governed plans.
  Future<void> _check(final List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'project',
        help: 'Project root (defaults to the current directory).',
      )
      ..addOption(
        'registry-root',
        help: 'Supervisor registry root (defaults to ~/.oka/supervisor).',
      )
      ..addFlag('json', negatable: false, help: 'Emit one JSON document.')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');
    final results = _parse(parser, args);
    if (results == null) return;
    if (results['help'] as bool) {
      _output(
        'oka supervisor check <plan.json> [--project <dir>] '
        '[--registry-root <dir>] [--json]\n'
        '${parser.usage}',
      );
      return;
    }
    if (results.rest.length != 1) {
      _errorOutput('Usage: oka supervisor check <plan.json> [flags]');
      _setExitCode(1);
      return;
    }

    final planPath = results.rest.single;
    final String document;
    try {
      document = File(planPath).readAsStringSync();
    } on Object catch (error) {
      _errorOutput('Cannot read supervisor plan "$planPath": $error');
      _setExitCode(1);
      return;
    }
    final DesiredState desired;
    try {
      desired = const SpecCodec().decode(document);
    } on SpecFormatException catch (error) {
      _errorOutput('$error');
      _setExitCode(1);
      return;
    }
    final failure = _providerPreflight(desired);
    if (failure != null) {
      _errorOutput(failure);
      _setExitCode(1);
      return;
    }

    final projectRoot =
        (results['project'] as String?) ?? Directory.current.path;
    final registry = _registry(results['registry-root'] as String?);
    final scope = registry.scopeFor(projectRoot);
    final snapshot = registry.snapshot(scope);
    final statuses = projectStatus(snapshot: snapshot, desired: desired);
    final problems = _checkProblems(statuses, snapshot.corruptPaths);

    if (results['json'] as bool) {
      _output(
        const JsonEncoder.withIndent('  ').convert({
          'statuses': [for (final status in statuses) status.toJson()],
          'corruptRecords': List<String>.of(snapshot.corruptPaths),
          'ok': problems.isEmpty,
          'problems': problems,
        }),
      );
    } else {
      if (statuses.isEmpty) {
        _output('no supervisor records for this project (scope $scope)');
      } else {
        _output(renderStatus(statuses));
      }
      if (problems.isEmpty) {
        _output('check ok: ${desired.specs.length} spec(s) match the records');
      } else {
        _output('check failed: ${problems.length} problem(s)');
        for (final problem in problems) {
          _output('  - $problem');
        }
      }
    }
    if (problems.isNotEmpty) _setExitCode(1);
  }

  /// The drift rules, named: a committed plan is honored when every
  /// service it declares has a record with a matching revision hash and
  /// no job ended failed, and no record file is corrupt.
  List<String> _checkProblems(
    final List<ComponentStatus> statuses,
    final List<String> corruptPaths,
  ) {
    final problems = <String>[
      for (final path in corruptPaths) 'corrupt record: $path',
    ];
    for (final status in statuses) {
      if (!status.present) {
        if (status.shape == 'service') {
          problems.add(
            'spec "${status.componentId}": declared service has no record '
            '(not converged)',
          );
        }
        continue;
      }
      if (status.drifted) {
        problems.add(
          'spec "${status.componentId}": record drifted from plan '
          '(${status.revisionHash} != ${status.desiredRevisionHash}); '
          'converge required',
        );
      }
      if (status.lastRun == 'failed') {
        problems.add('spec "${status.componentId}": last run failed');
      }
    }
    return problems;
  }

  MachineRegistry _registry(final String? registryRoot) =>
      registryRoot == null || registryRoot.isEmpty
      ? MachineRegistry.forMachine()
      : MachineRegistry(root: registryRoot);

  ArgResults? _parse(final ArgParser parser, final List<String> args) {
    try {
      return parser.parse(args);
    } on ArgParserException catch (error) {
      _errorOutput('Invalid supervisor arguments: ${error.message}');
      _errorOutput(parser.usage);
      _setExitCode(1);
      return null;
    }
  }

  static const _processProviderName = 'process';

  static const _usage =
      'oka supervisor [status | apply <plan.json> | check <plan.json>] — '
      'declarative process supervision (ADR-0040/0041)\n'
      '  status   Show recorded component state for one project\n'
      '  apply    Converge one pass from an authored plan document\n'
      '  check    Drift gate: plan vs records, read-only (CI hook)\n'
      'Run `oka supervisor <subcommand> --help` for per-subcommand flags.';
}

/// Routes the substrate's provider seam to one [LeasedProcessProvider]
/// per declared component: a [ProviderFactory] sees only the provider
/// name, while start/stop/inspect calls always carry the component
/// identity, so per-component commands stay constructor-injected.
final class _ProcessProviderRouter implements ResourceProvider {
  _ProcessProviderRouter({
    required final DesiredState desired,
    required final String projectRoot,
  }) : _providers = {
         for (final spec in desired.specs)
           spec.id: LeasedProcessProvider(
             leaseId: spec.id,
             command: ProcessCommand(
               spec.env[_commandEnvKey]!,
               _splitArgs(spec.env[_argsEnvKey]),
             ),
             registry: ProcessLeaseRegistry.forProject(projectRoot),
           ),
       };

  static const _commandEnvKey = 'command';
  static const _argsEnvKey = 'args';

  final Map<String, LeasedProcessProvider> _providers;

  /// The factory the supervisor composes with: only `process` resolves;
  /// anything else is a declaration bug, never a crash path.
  ResourceProvider factory(final String name) {
    if (name != SupervisorCommand._processProviderName) {
      throw StateError(
        'unknown provider "$name"; this CLI provides: '
        '${SupervisorCommand._processProviderName}',
      );
    }
    return this;
  }

  LeasedProcessProvider _for(final String componentId) {
    final provider = _providers[componentId];
    if (provider == null) {
      throw StateError(
        'no process provider composed for component "$componentId"',
      );
    }
    return provider;
  }

  static List<String> _splitArgs(final String? line) =>
      (line ?? '').split(' ').where((final part) => part.isNotEmpty).toList();

  @override
  ProviderCapabilities get capabilities =>
      const ProviderCapabilities(readinessProbe: true, durableIdentity: true);

  @override
  Future<StartReport> start(final StartRequest request) =>
      _for(request.component.id).start(request);

  @override
  Future<Observation> inspect(final ResourceRef ref) =>
      _for(ref.componentId).inspect(ref);

  @override
  Future<StopReport> stop(
    final ResourceRef ref, {
    required final Duration grace,
  }) => _for(ref.componentId).stop(ref, grace: grace);

  @override
  Future<Observation> reconcile(final ResourceRef ref) =>
      _for(ref.componentId).reconcile(ref);
}
