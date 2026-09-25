/// `oka cache` — storage inventory/pruning (ADR-0019) and indexed shared
/// artifact views (ADR-0013).
///
/// Subcommands (views over [ArtifactStore] — the Dart API is the agent
/// surface, these are conveniences for humans):
///
/// * `oka cache stats [--json]` — cross-platform directory storage inventory.
/// * `oka cache prune [--apply]` — preview, then explicitly execute cleanup.
/// * `oka cache list [--json]` — table of all store entries.
/// * `oka cache gc --older-than=<n>d|h|m [--max-size=<N>[K|M|G]] [--dry-run]`
///   — purge by explicit criteria only; never interactive.
/// * `oka cache why <category[/name[/version]]>` — which key/path a given
///   artifact maps to.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;

import '../../cache/cache_transactions.dart';
import '../../cache/cache_workspace.dart';
import 'artifact_store_command.dart';
import 'parsers.dart';
import 'renderers.dart';
import 'schema.dart';

/// Usage/exit signal for the cache command: [exitCode] is what the CLI
/// top-level should terminate with after printing the message.
class CacheCommandError implements Exception {
  const CacheCommandError(this.exitCode, this.message);
  final int exitCode;
  final String message;
  @override
  String toString() => message;
}

/// Cache inspection command (ADR-0013).
class CacheCommand {
  CacheCommand({
    final void Function(String message)? out,
    final LocalArtifactStore? store,
    this.inventory,
    this.environment,
    this.currentDirectory,
    this.diagnosticProviders,
  }) : _out = out ?? print,
       _store = store ?? LocalArtifactStore();
  final void Function(String message) _out;
  final LocalArtifactStore _store;
  final StorageInventory? inventory;
  final Map<String, String>? environment;
  final String? currentDirectory;

  /// Replace or extend the same providers used by the public Dart API.
  final List<CacheDiagnosticProvider>? diagnosticProviders;

  CacheTransactions get _transactions => CacheTransactions(
    workspaces: CacheWorkspaceRepository(
      environment: environment,
      currentDirectory: currentDirectory,
      // Android knowledge stays in oka_android (ADR-0022): the CLI only
      // forwards the guidance to the generic discovery layer.
      toolGuidance: okaProvisionedToolGuidance,
    ),
    diagnosticProviders: diagnosticProviders,
    environment: environment,
  );

  ArtifactStoreCommand get _artifacts => ArtifactStoreCommand(
    store: _store,
    out: _out,
    usageError: CacheCommandError.new,
  );

  Future<void> run(final List<String> args) async {
    if (args.isEmpty ||
        (args.first.startsWith('-') &&
            !['--help', '-h'].contains(args.first))) {
      await _stats(args);
      return;
    }
    final subcommand = args.first;
    final rest = args.skip(1).toList();
    switch (subcommand) {
      case '--help':
      case '-h':
        _printUsage();
      case 'stats':
        await _stats(rest);
      case 'prune':
      case 'clean':
        await _prune(rest);
      case 'schema':
        if (rest.any((final arg) => arg != '--json')) {
          throw const CacheCommandError(64, 'Usage: oka cache schema');
        }
        _schema();
      case 'list':
        await _artifacts.list(rest);
      case 'gc':
        await _artifacts.gc(rest);
      case 'why':
        await _artifacts.why(rest);
      default:
        throw CacheCommandError(
          64,
          'Unknown cache subcommand: $subcommand. Use oka cache --help.',
        );
    }
  }

  ArgParser _storageParser() => ArgParser()
    ..addOption(
      'project',
      help: 'Only this project (default: all known projects)',
    )
    ..addFlag(
      'global',
      negatable: false,
      help: 'All known projects + shared storage (default)',
    )
    ..addMultiOption(
      'scan',
      splitCommas: false,
      help: 'Find and remember projects below this directory; repeatable',
    )
    ..addFlag(
      'details',
      negatable: false,
      help: 'Show all storage and diagnostic records',
    )
    ..addFlag('json', negatable: false, help: 'Machine-readable JSON output')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');

  Future<CacheWorkspace> _storage(
    final ArgResults results, {
    List<String>? savedProjects,
    bool inspection = false,
  }) async {
    final project = results['project'] as String?;
    final roots = results['scan'] as List<String>;
    if (project != null && ((results['global'] as bool) || roots.isNotEmpty)) {
      throw const CacheCommandError(
        64,
        '--project cannot be combined with --global or --scan',
      );
    }
    if (inventory != null) {
      return CacheWorkspace(
        inventory: inventory!,
        projects: const [],
        global: project == null,
      );
    }
    return loadCacheWorkspace(
      projectPath: project,
      scanRoots: roots,
      savedProjects: savedProjects,
      environment: environment,
      currentDirectory: currentDirectory,
      inspection: inspection,
      // Android knowledge stays in oka_android (ADR-0022): the CLI only
      // forwards the guidance to the generic discovery layer.
      toolGuidance: okaProvisionedToolGuidance,
    );
  }

  List<String> _targetArgs(final ArgResults results) => [
    if (results['project'] != null) ...[
      '--project',
      results['project'] as String,
    ] else
      '--global',
  ];

  Map<String, Object?> _action(
    String id,
    List<String> argv,
    String description, {
    bool destructive = false,
  }) => {
    'id': id,
    'argv': argv,
    'description': description,
    'destructive': destructive,
    'cwd': p.absolute(currentDirectory ?? Directory.current.path),
  };

  void _coverage(CacheWorkspace workspace) {
    _out(
      '${workspace.global ? 'Global' : 'Project'} storage: ${workspace.projects.length} known project(s) + shared storage.',
    );
    for (final warning in workspace.warnings) {
      _out('Warning: $warning');
    }
    if (workspace.global) {
      _out('Find older projects: oka cache --scan <code-directory>');
    }
  }

  Future<void> _stats(final List<String> args) async {
    final parser = _storageParser()
      ..addMultiOption(
        'kind',
        help: 'Diagnostic kind to show; repeatable, implies --details',
      );
    final results = parser.parse(args);
    if (results['help'] as bool) {
      _out('Usage: oka cache stats [options]\n${parser.usage}');
      return;
    }
    if (results.rest.isNotEmpty) {
      throw const CacheCommandError(64, 'Unexpected arguments to cache stats');
    }
    final kinds = (results['kind'] as List<String>).toSet();
    final details = (results['details'] as bool) || kinds.isNotEmpty;
    final scanRoots = results['scan'] as List<String>;
    if (scanRoots.isNotEmpty && results['project'] != null) {
      throw const CacheCommandError(
        64,
        '--project cannot be combined with --global or --scan',
      );
    }
    final CacheInspectResult inspected;
    if (inventory == null && scanRoots.isNotEmpty) {
      inspected = await _transactions.discoverAndInspect(
        CacheWorkspaceRequest(scanRoots: scanRoots),
        CacheInspectRequest(kinds: kinds),
      );
    } else {
      final workspace = await _storage(results, inspection: true);
      inspected = await _transactions.inspectWorkspace(
        workspace,
        CacheInspectRequest(kinds: kinds),
      );
    }
    final workspace = inspected.workspace;
    final report = inspected.storage;
    final diagnostics = inspected.diagnostics;
    final reclaimable = inspected.cleanup.selectedBytes;
    final preserved = (report.totalBytes - reclaimable).clamp(
      0,
      report.totalBytes,
    );
    final nextActions = [
      _action('preview_cleanup', [
        'oka',
        'cache',
        'clean',
        ..._targetArgs(results),
      ], 'Preview reproducible build and shared cache cleanup'),
    ];
    if (results['json'] as bool) {
      _out(
        const JsonEncoder.withIndent('  ').convert({
          'schema_version': 'oka.cache.stats.v1',
          ...report.toJson(),
          'discovery': workspace.toJson(),
          'reclaimable_bytes': reclaimable,
          'preserved_bytes': preserved,
          'reclaimable_scopes': ['build', 'shared'],
          'next_actions': nextActions,
          'diagnostics': diagnostics.toJson(),
        }),
      );
      return;
    }
    _coverage(workspace);
    _out(
      '${_formatBytes(reclaimable)} reclaimable (build + shared) · ${_formatBytes(preserved)} preserved',
    );
    _out('Logical file bytes; filesystem allocation may differ.');
    final locations = [...report.locations]
      ..sort((final a, final b) => b.sizeBytes.compareTo(a.sizeBytes));
    for (final entry
        in kinds.isNotEmpty
            ? <StorageMeasurement>[]
            : details
            ? locations
            : locations.take(8)) {
      final location = entry.location;
      _out(
        '\n${_formatBytes(entry.sizeBytes)}  ${location.category} '
        '[${location.platform}]',
      );
      _out('  ${location.path}');
      _out(
        '  ${location.ownership}; '
        '${location.prunable && entry.complete ? 'prunable (${location.scope})' : 'preserved'}',
      );
      if (location.note != null) _out('  ${location.note}');
      for (final warning in entry.warnings) {
        _out('  Warning: $warning');
      }
    }
    _out(
      '\n${report.locations.any((final e) => !e.complete) ? 'At least ' : ''}'
      '${_formatBytes(report.totalBytes)} across discovered locations.',
    );
    if (locations.length > 8 && !details) {
      _out(
        '${locations.length - 8} more locations: add --details (JSON always includes all).',
      );
    }
    _out(
      'Preview cleanup: ${_displayArgv(nextActions.single['argv']! as List<String>)}',
    );
    _out(
      'Emulator/simulator directories describe stored data, not running status.',
    );
    _diagnosticOutput(diagnostics, details: details);
  }

  void _diagnosticOutput(
    CacheDiagnosticReport report, {
    required bool details,
  }) {
    final counts = <String, int>{};
    for (final record in report.records) {
      counts.update(record.kind, (count) => count + 1, ifAbsent: () => 1);
    }
    _out(
      '\nDiagnostics: ${counts.entries.map((e) => '${e.value} ${e.key}').join(', ')}${report.records.isEmpty ? 'no matching records' : ''}.',
    );
    if (!details) {
      _out(
        'Inspect metadata and sessions: oka cache --details (or --kind session)',
      );
    }
    if (details) {
      for (final record in report.records) {
        _out('\n${record.kind}  ${record.label} [${record.platform}]');
        _out('  id: ${record.id}');
        if (record.projectPath != null) {
          _out('  project: ${record.projectPath}');
        }
        if (record.path != null) _out('  path: ${record.path}');
        for (final observation in record.observations) {
          _out(
            '  ${observation.source.name}: ${observation.status} @ ${observation.observedAt.toUtc().toIso8601String()}${observation.detail == null ? '' : ' — ${observation.detail}'}',
          );
        }
        for (final field in record.metadata.entries) {
          _out('  ${field.key}: ${jsonEncode(field.value)}');
        }
        if (record.relatedIds.isNotEmpty) {
          _out('  related: ${record.relatedIds.join(', ')}');
        }
        for (final action in record.actions) {
          _out(
            '  ${action.label}: ${_displayArgv(action.argv)} (cwd: ${action.cwd})',
          );
        }
      }
    }
    for (final issue in report.issues) {
      _out(
        'Warning [${issue.providerId}/${issue.code}]: ${issue.message}${issue.path == null ? '' : ' (${issue.path})'}',
      );
    }
  }

  Future<void> _prune(final List<String> args) async {
    final parser = _storageParser()
      ..addMultiOption(
        'scope',
        allowed: ['build', 'shared', 'tools'],
        defaultsTo: ['build', 'shared'],
        help: 'Eligible storage scopes (comma-separated)',
      )
      ..addOption(
        'older-than',
        help: 'Latest modification age, e.g. 30d, 12h, 45m; not last use',
      )
      ..addOption(
        'max-size',
        help: 'Remaining eligible pool budget, e.g. 2G, 2GB, 500MiB',
      )
      ..addFlag('apply', negatable: false, help: 'Delete the selected caches')
      ..addFlag('dry-run', negatable: false, help: 'Preview only (the default)')
      ..addFlag(
        'interactive',
        negatable: false,
        help: 'Preview then ask before applying (terminal only)',
      )
      ..addOption(
        'save-plan',
        help: 'Save an exact cleanup preview to a new JSON file',
      )
      ..addOption(
        'apply-plan',
        help: 'Apply only the reviewed entries from a saved plan',
      );
    final results = parser.parse(args);
    if (results['help'] as bool) {
      _out(
        'Usage: oka cache clean [options] (prune is an alias)\n${parser.usage}\n'
        'Without age/budget criteria, selects all eligible caches in scope.\n'
        'Preserves SDKs, emulator/simulator data, browser profiles and process leases.',
      );
      return;
    }
    if (results.rest.isNotEmpty) {
      throw const CacheCommandError(64, 'Unexpected arguments to cache prune');
    }
    final interactive = results['interactive'] as bool;
    final savePath = results['save-plan'] as String?;
    final applyPath = results['apply-plan'] as String?;
    if (applyPath != null) {
      for (final flag in [
        'project',
        'global',
        'scan',
        'scope',
        'older-than',
        'max-size',
        'apply',
        'dry-run',
        'interactive',
        'save-plan',
      ]) {
        if (results.wasParsed(flag)) {
          throw CacheCommandError(
            64,
            '--apply-plan cannot be combined with --$flag',
          );
        }
      }
      late final CacheCleanupPlanRecord record;
      late final CacheWorkspace workspace;
      late final StoragePruneResult result;
      try {
        record = await _transactions.plans.read(applyPath);
        workspace = await _storage(results, savedProjects: record.projects);
        result = await _transactions.apply(
          CacheWorkspaceRequest.saved(record.projects),
          record.plan,
        );
      } on FormatException catch (error) {
        throw CacheCommandError(64, error.message);
      }
      _pruneOutput(result, results, workspace, const []);
      return;
    }
    if (interactive &&
        ((results['apply'] as bool) ||
            (results['dry-run'] as bool) ||
            (results['json'] as bool) ||
            savePath != null)) {
      throw const CacheCommandError(
        64,
        '--interactive cannot be combined with --apply, --dry-run, --json or --save-plan',
      );
    }
    if (interactive && (!stdin.hasTerminal || !stdout.hasTerminal)) {
      throw const CacheCommandError(
        64,
        '--interactive requires a terminal; use --save-plan and --apply-plan for automation',
      );
    }
    if (savePath != null && results['apply'] as bool) {
      throw const CacheCommandError(
        64,
        '--save-plan previews only; use --apply-plan to execute it',
      );
    }
    if (results['apply'] as bool && results['dry-run'] as bool) {
      throw const CacheCommandError(
        64,
        'Choose --apply or --dry-run, not both',
      );
    }
    final age = results['older-than'] as String?;
    final size = results['max-size'] as String?;
    final olderThan = age == null ? null : _parseDuration(age);
    final maxBytes = size == null ? null : _parseSize(size);
    if (age != null && olderThan == null) {
      throw const CacheCommandError(64, 'Invalid age; use e.g. 30d, 12h, 45m');
    }
    if (size != null && maxBytes == null) {
      throw const CacheCommandError(
        64,
        'Invalid size; use bytes, K/M/G/T, KB/MB/GB/TB or KiB/MiB/GiB/TiB',
      );
    }
    final apply = results['apply'] as bool;
    final workspace = await _storage(results);
    final cleanupRequest = CacheCleanupRequest(
      scopes: (results['scope'] as List<String>).toSet(),
      olderThan: olderThan,
      maxTotalBytes: maxBytes,
    );
    final preview = await _transactions.preview(workspace, cleanupRequest);
    final result = apply
        ? inventory != null
              ? await workspace.inventory.applyPlan(
                  StorageCleanupPlan(selected: preview.selected),
                )
              : await _transactions.apply(
                  CacheWorkspaceRequest.saved(workspace.projects),
                  StorageCleanupPlan(selected: preview.selected),
                )
        : preview;
    final nextActions = <Map<String, Object?>>[];
    if (savePath != null) {
      final path = p.absolute(savePath);
      try {
        await _transactions.savePlan(path, workspace, result);
      } on FormatException catch (error) {
        throw CacheCommandError(64, error.message);
      }
      nextActions.add(
        _action(
          'apply_saved_plan',
          ['oka', 'cache', 'clean', '--apply-plan', path],
          'Apply only saved entries after revalidation',
          destructive: true,
        ),
      );
    } else if (!apply && !interactive) {
      nextActions.add(
        _action(
          'apply_cleanup',
          [
            'oka',
            'cache',
            'clean',
            ..._targetArgs(results),
            '--scope',
            (results['scope'] as List<String>).join(','),
            if (age != null) ...['--older-than', age],
            if (size != null) ...['--max-size', size],
            '--apply',
          ],
          'Recalculate and apply this cleanup selection',
          destructive: true,
        ),
      );
    }
    _pruneOutput(result, results, workspace, nextActions);
    if (interactive && result.selected.isNotEmpty) {
      stdout.write(
        'Remove these ${result.selected.length} locations (${_formatBytes(result.selectedBytes)})? [y/N] ',
      );
      final answer = stdin.readLineSync()?.trim().toLowerCase();
      if (answer != 'y' && answer != 'yes') {
        _out('Cancelled. No caches deleted.');
        return;
      }
      // Re-discover session protections after the user has reviewed the paths.
      final fresh = await _storage(results, savedProjects: workspace.projects);
      final applied = inventory != null
          ? await fresh.inventory.applyPlan(
              StorageCleanupPlan(selected: result.selected),
            )
          : await _transactions.apply(
              CacheWorkspaceRequest.saved(workspace.projects),
              StorageCleanupPlan(selected: result.selected),
            );
      _pruneOutput(applied, results, fresh, const []);
    }
  }

  void _pruneOutput(
    StoragePruneResult result,
    ArgResults results,
    CacheWorkspace workspace,
    List<Map<String, Object?>> nextActions,
  ) {
    if (results['json'] as bool) {
      _out(
        const JsonEncoder.withIndent('  ').convert({
          'schema_version': 'oka.cache.prune.v1',
          ...result.toJson(),
          'discovery': workspace.toJson(),
          if (workspace.inventory.protectedPaths.isNotEmpty)
            'safety_notes': [
              'Session-state deletion is protected against known paths, but not against same-user filesystem races.',
            ],
          'next_actions': nextActions,
        }),
      );
    } else {
      _coverage(workspace);
      if (workspace.inventory.protectedPaths.isNotEmpty) {
        _out(
          'Session-state deletion is protected against known paths, but not '
          'against same-user filesystem races.',
        );
      }
      _out(
        '${result.apply ? 'Selected' : 'Would prune'} ${result.selected.length} locations, '
        '${_formatBytes(result.selectedBytes)} logical bytes',
      );
      for (final entry in result.selected) {
        _out('  ${_formatBytes(entry.sizeBytes)}  ${entry.location.path}');
      }
      if (result.apply) {
        _out(
          'Deleted ${result.deleted.length} locations, '
          '${_formatBytes(result.freedBytes)} logical bytes.',
        );
      } else {
        _out('Preview only. No caches deleted.');
      }
      for (final action in nextActions) {
        _out('Next: ${_displayArgv(action['argv']! as List<String>)}');
      }
      for (final error in result.errors) {
        _out('  $error');
      }
    }
    if (result.apply && result.errors.isNotEmpty) {
      throw const CacheCommandError(
        1,
        'Some cache locations could not be pruned',
      );
    }
  }

  String _displayArgv(List<String> argv) => displayCacheArgv(argv);

  void _schema() => _out(cacheInterfaceSchemaJson());

  void _printUsage() {
    _out('Usage: oka cache [options]');
    _out(
      '  oka cache             Overview of all known projects + shared storage',
    );
    _out('  oka cache --scan DIR  Find and remember projects under DIR');
    _out('  oka cache clean       Preview cleanup; add --apply to execute');
    _out('  oka cache clean --interactive  Review and confirm in a terminal');
    _out('  oka cache schema      Machine-readable interface (no scan)');
    _out(
      '  --project PATH        Narrow to one project; --global is the default',
    );
    _out(
      '  --json                Structured output with next-action argv arrays',
    );
    _out(
      '  --details             Every storage location and diagnostic record',
    );
    _out('  --kind KIND           Filter diagnostic records; repeatable');
    _out('');
    _out(
      '  stats [--json]        Storage by path/platform, including emulators',
    );
    _out(
      '  prune [--apply]       Preview eligible cache cleanup; --apply deletes',
    );
    _out(
      '  clean --save-plan FILE / clean --apply-plan FILE  Review an exact selection',
    );
    _out('  list                  Show all artifact store entries');
    _out(
      '  gc                    Purge by explicit criteria (--older-than / '
      '--max-size); never interactive',
    );
    _out('  why <category[/name[/version]]>');
    _out('');
    _out(
      'Store root: ${LocalArtifactStore.defaultRoot()} '
      '(override with OKA_CACHE)',
    );
  }

  Duration? _parseDuration(final String raw) => parseCacheDuration(raw);

  /// Parses bytes or K/M/G/T, KB and KiB-style suffixes (binary multiples).
  int? _parseSize(final String raw) => parseCacheSize(raw);

  String _formatBytes(final int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
