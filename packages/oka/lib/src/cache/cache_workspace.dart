import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'storage_discovery.dart';

/// Resolved project coverage and one deduplicated storage inventory.
class CacheWorkspace {
  const CacheWorkspace({
    required this.inventory,
    required this.projects,
    required this.global,
    this.scanRoots = const [],
    this.warnings = const [],
    this.complete = true,
  });
  final StorageInventory inventory;
  final List<String> projects;
  final bool global;
  final List<String> scanRoots;
  final List<String> warnings;
  final bool complete;

  Map<String, Object?> toJson() => {
    'mode': global ? 'global' : 'project',
    'projects': projects,
    'project_count': projects.length,
    'scan_roots': scanRoots,
    'complete': complete,
    'warnings': warnings,
    'coverage':
        'Known projects plus shared storage; not an exhaustive disk scan.',
  };
}

abstract interface class CacheProjectSource {
  Future<CacheProjectRegistrySnapshot> inspect();
  Future<List<String>> projects();
  Future<ProjectDiscovery> discover(List<String> roots);
  Future<void> register(String project);
}

final class RegistryCacheProjectSource implements CacheProjectSource {
  RegistryCacheProjectSource(this.registry);
  final CacheProjectRegistry registry;

  @override
  Future<ProjectDiscovery> discover(List<String> roots) =>
      registry.discover(roots);
  @override
  Future<CacheProjectRegistrySnapshot> inspect() => registry.inspect();
  @override
  Future<List<String>> projects() => registry.projects();
  @override
  Future<void> register(String project) => registry.register(project);
}

typedef CacheLocationSource =
    Future<List<StorageLocation>> Function({
      required String projectPath,
      required Map<String, String> environment,
      required bool includeShared,
      required bool includeProject,
      required ProcessLiveness liveness,
      List<({String match, String guidance})> toolGuidance,
    });

Future<List<StorageLocation>> defaultCacheLocationSource({
  required String projectPath,
  required Map<String, String> environment,
  required bool includeShared,
  required bool includeProject,
  required ProcessLiveness liveness,
  List<({String match, String guidance})> toolGuidance = const [],
}) => discoverStorageLocations(
  projectPath: projectPath,
  environment: environment,
  includeShared: includeShared,
  includeProject: includeProject,
  liveness: liveness,
  toolGuidance: toolGuidance,
);

final class CacheWorkspaceRequest {
  const CacheWorkspaceRequest({
    this.projectPath,
    this.scanRoots = const [],
    this.savedProjects,
  });

  const CacheWorkspaceRequest.saved(List<String> projects)
    : projectPath = null,
      scanRoots = const [],
      savedProjects = projects;

  final String? projectPath;
  final List<String> scanRoots;
  final List<String>? savedProjects;
}

/// Separates read-only inspection from explicit discovery and registration.
final class CacheWorkspaceRepository {
  CacheWorkspaceRepository({
    Map<String, String>? environment,
    String? currentDirectory,
    CacheProjectSource? projects,
    this.locations = defaultCacheLocationSource,
    this.toolGuidance = const [],
    this.liveness = const HostProcessLiveness(),
  }) : environment = environment ?? Platform.environment,
       currentDirectory = currentDirectory ?? Directory.current.path,
       projects =
           projects ??
           RegistryCacheProjectSource(
             CacheProjectRegistry(
               environment: environment ?? Platform.environment,
             ),
           );

  final Map<String, String> environment;
  final String currentDirectory;
  final CacheProjectSource projects;
  final CacheLocationSource locations;

  /// Per-tool guidance forwarded to [locations]; supplied by the CLI
  /// composition root from oka_android (ADR-0022: Android knowledge stays
  /// in the platform package; this layer stays generic).
  final List<({String match, String guidance})> toolGuidance;
  final ProcessLiveness liveness;

  Future<CacheWorkspace> inspect([
    CacheWorkspaceRequest request = const CacheWorkspaceRequest(),
  ]) => _load(request, inspection: true, remember: false);

  Future<CacheWorkspace> read([
    CacheWorkspaceRequest request = const CacheWorkspaceRequest(),
  ]) => _load(request, inspection: false, remember: false);

  Future<CacheWorkspace> discoverAndRemember(CacheWorkspaceRequest request) =>
      _load(request, inspection: false, remember: true);

  Future<CacheWorkspace> _load(
    CacheWorkspaceRequest request, {
    required bool inspection,
    required bool remember,
  }) => _loadCacheWorkspace(
    projectPath: request.projectPath,
    scanRoots: request.scanRoots,
    savedProjects: request.savedProjects,
    environment: environment,
    currentDirectory: currentDirectory,
    inspection: inspection,
    remember: remember,
    projectSource: projects,
    locationSource: locations,
    toolGuidance: toolGuidance,
    liveness: liveness,
  );
}

Future<CacheWorkspace> loadCacheWorkspace({
  String? projectPath,
  List<String> scanRoots = const [],
  List<String>? savedProjects,
  Map<String, String>? environment,
  String? currentDirectory,
  bool inspection = false,
  List<({String match, String guidance})> toolGuidance = const [],
}) {
  final repository = CacheWorkspaceRepository(
    environment: environment,
    currentDirectory: currentDirectory,
    toolGuidance: toolGuidance,
  );
  final request = CacheWorkspaceRequest(
    projectPath: projectPath,
    scanRoots: scanRoots,
    savedProjects: savedProjects,
  );
  if (scanRoots.isNotEmpty) {
    return repository.discoverAndRemember(request);
  }
  if (inspection) return repository.inspect(request);
  if (savedProjects == null) return repository.discoverAndRemember(request);
  return repository.read(request);
}

Future<CacheWorkspace> _loadCacheWorkspace({
  required Map<String, String> environment,
  required String currentDirectory,
  required bool inspection,
  required bool remember,
  required CacheProjectSource projectSource,
  required CacheLocationSource locationSource,
  required ProcessLiveness liveness,
  required List<({String match, String guidance})> toolGuidance,
  String? projectPath,
  List<String> scanRoots = const [],
  List<String>? savedProjects,
}) async {
  final env = environment;
  final warnings = <String>[];
  var complete = true;
  final projects = <String>{};
  final cwd = currentDirectory;

  if (savedProjects != null) {
    // Saved paths identify project roots only. Discovery reconstructs deletion
    // eligibility and session protection; plan metadata is never authority.
    for (final path in savedProjects) {
      if (!p.isAbsolute(path)) {
        throw const FormatException('Plan project paths must be absolute');
      }
      if (await Directory(path).exists()) projects.add(p.normalize(path));
    }
  } else if (projectPath != null) {
    final project = Directory(p.absolute(projectPath));
    if (!await project.exists()) {
      throw ArgumentError('Project directory does not exist: ${project.path}');
    }
    projects.add(project.path);
  } else {
    if (scanRoots.isNotEmpty && remember) {
      final discovered = await projectSource.discover(scanRoots);
      warnings.addAll(discovered.warnings);
      complete = discovered.complete;
    }
    if (inspection) {
      final snapshot = await projectSource.inspect();
      warnings.addAll(snapshot.issues.map((issue) => issue.message));
      complete = complete && snapshot.complete;
      for (final project in snapshot.projects) {
        if (await FileSystemEntity.type(
                  p.join(project, '.oka_cache'),
                  followLinks: false,
                ) ==
                FileSystemEntityType.directory &&
            await FileSystemEntity.type(project, followLinks: false) ==
                FileSystemEntityType.directory &&
            await Directory(project).resolveSymbolicLinks() ==
                p.normalize(project)) {
          projects.add(project);
        }
      }
    } else {
      projects.addAll(await projectSource.projects());
    }
    if (await Directory(p.join(cwd, '.oka_cache')).exists()) {
      projects.add(p.normalize(p.absolute(cwd)));
    }
  }

  if (savedProjects == null && remember) {
    for (final project in projects) {
      if (!await Directory(p.join(project, '.oka_cache')).exists()) continue;
      try {
        await projectSource.register(project);
      } on Object catch (error) {
        warnings.add('Could not remember project $project: $error');
        complete = false;
      }
    }
  }

  final sorted = projects.toList()..sort();
  final locations = <String, StorageLocation>{};
  void addLocations(List<StorageLocation> additions) {
    for (final location in additions) {
      final key = p.normalize(p.absolute(location.path));
      final prior = locations[key];
      if (prior == null || (prior.prunable && !location.prunable)) {
        locations[key] = location;
      }
    }
  }

  // Shared platform discovery runs once, not once per registered project.
  addLocations(
    await locationSource(
      projectPath: sorted.isEmpty ? cwd : sorted.first,
      environment: env,
      includeShared: true,
      includeProject: sorted.isNotEmpty,
      liveness: liveness,
      toolGuidance: toolGuidance,
    ),
  );
  for (final project in sorted.skip(1)) {
    addLocations(
      await locationSource(
        projectPath: project,
        environment: env,
        includeShared: false,
        includeProject: true,
        liveness: liveness,
        toolGuidance: toolGuidance,
      ),
    );
  }
  return CacheWorkspace(
    inventory: StorageInventory(
      locations: locations.values.toList(),
      protectedRoots: [env['HOME'], env['USERPROFILE']].whereType<String>(),
    ),
    projects: sorted,
    global: projectPath == null,
    scanRoots: scanRoots,
    warnings: warnings,
    complete: complete,
  );
}
