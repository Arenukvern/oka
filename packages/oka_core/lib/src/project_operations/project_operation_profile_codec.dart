/// The strict codec for a declared project operation profile.
///
/// A project declares its operations in `.oka/project_operations.json`, at the
/// project root. The file carries the *evidence shape* of a profile — the JSON
/// [ProjectOperationProfile.toJson] produces — so a declaration and a shipped
/// fixture are the same kind of data, and a round trip through this codec
/// preserves that shape.
///
/// The decoder is strict on purpose. A declaration is a promise about the
/// commands a project publishes; a best-effort repair would turn a typo into
/// a command the project never published. Every refusal therefore carries a
/// named reason, and no refusal ever echoes an environment value.
///
/// Decoding reads a file. It never starts a process, probes an endpoint or
/// infers a command from a file name: there is no auto-detection layer here.
library;

import 'dart:convert';
import 'dart:io';

import 'project_operation_profile.dart';

/// A refused declaration.
///
/// The [reason] is a stable name; the [detail] names keys and shapes, never
/// values.
final class ProjectOperationProfileFormatException implements Exception {
  /// Describes one refusal.
  const ProjectOperationProfileFormatException(this.reason, this.detail);

  /// The named reason, e.g. `project_operation_profile_duplicate_kind`.
  final String reason;

  /// The human detail of the refusal.
  final String detail;

  @override
  String toString() => '$reason: $detail';
}

/// Reads and writes the declaration file of a project.
final class ProjectOperationProfileCodec {
  const ProjectOperationProfileCodec._();

  /// The declaration path, relative to the project root.
  static const String declarationPath = '.oka/project_operations.json';

  /// The largest declaration this codec reads.
  static const int maxDeclarationBytes = 256 * 1024;

  /// The longest accepted profile or operation id.
  static const int maxIdLength = 64;

  /// The longest accepted command budget.
  static const Duration maxBudget = Duration(days: 7);

  /// Decodes a profile from the JSON text of a declaration.
  ///
  /// Throws [ProjectOperationProfileFormatException] when the declaration is
  /// refused. Nothing is repaired and nothing is defaulted beyond the fields
  /// the evidence shape itself may omit.
  static ProjectOperationProfile decode(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw ProjectOperationProfileFormatException(
        'project_operation_profile_not_json',
        'the declaration is not JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_not_object',
        'the declaration must be a JSON object',
      );
    }
    return _profile(decoded);
  }

  /// Encodes a profile into the JSON text of a declaration.
  ///
  /// The text is the evidence shape of the profile, indented for a file a
  /// person reads. `decode(encode(profile))` carries the same shape back.
  static String encode(ProjectOperationProfile profile) =>
      const JsonEncoder.withIndent('  ').convert(profile.toJson());

  /// The declaration file of [workspace], when the project has one.
  static File? declarationFile(Directory workspace) {
    final file = File('${workspace.path}/$declarationPath');
    return file.existsSync() ? file : null;
  }

  /// Reads the declared profile of [workspace].
  ///
  /// Returns null when the project declared nothing. Throws
  /// [ProjectOperationProfileFormatException] when the declaration is
  /// refused. Reading a declaration starts no process and probes no endpoint.
  static ProjectOperationProfile? loadDeclaredProfile(Directory workspace) {
    final file = declarationFile(workspace);
    if (file == null) return null;
    if (file.lengthSync() > maxDeclarationBytes) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_too_large',
        'the declaration is larger than the accepted bound',
      );
    }
    return decode(file.readAsStringSync());
  }

  static ProjectOperationProfile _profile(Map<String, dynamic> json) {
    _rejectUnknownKeys(json, const {'id', 'operations', 'externalPackageRoots'});
    final id = _id(json, 'id', 'the profile');
    final operationsJson = json['operations'];
    if (operationsJson is! List) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_missing_operations',
        'the profile must declare a list of operations',
      );
    }
    if (operationsJson.isEmpty) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_no_operations',
        'the profile declares no operation',
      );
    }
    final operations = <ProjectOperation>[];
    final ids = <String>{};
    final kinds = <ProjectOperationKind>{};
    for (final entry in operationsJson) {
      if (entry is! Map<String, dynamic>) {
        throw const ProjectOperationProfileFormatException(
          'project_operation_profile_invalid_operation',
          'every declared operation must be a JSON object',
        );
      }
      final operation = _operation(entry);
      if (!ids.add(operation.id)) {
        throw ProjectOperationProfileFormatException(
          'project_operation_profile_duplicate_operation',
          'the operation id "${operation.id}" is declared twice',
        );
      }
      if (!kinds.add(operation.kind)) {
        throw ProjectOperationProfileFormatException(
          'project_operation_profile_duplicate_kind',
          'the ${operation.kind.name} operation is declared twice; a profile '
              'declares one operation per kind',
        );
      }
      operations.add(operation);
    }
    return ProjectOperationProfile(
      id: id,
      operations: List.unmodifiable(operations),
      externalPackageRoots: _packageRoots(json['externalPackageRoots']),
    );
  }

  static ProjectOperation _operation(Map<String, dynamic> json) {
    _rejectUnknownKeys(json, const {
      'id',
      'kind',
      'command',
      'endpoint',
      'readiness',
    });
    final id = _id(json, 'id', 'the operation');
    final kindName = json['kind'];
    if (kindName is! String) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_unknown_kind',
        'the operation must declare a kind',
      );
    }
    final kind = _kindOf(ProjectOperationKind.values, kindName);
    if (kind == null) {
      throw ProjectOperationProfileFormatException(
        'project_operation_profile_unknown_kind',
        'the operation kind "$kindName" is not one of '
            '${ProjectOperationKind.values.map((candidate) => candidate.name).join(', ')}',
      );
    }
    final commandJson = json['command'];
    if (commandJson is! Map<String, dynamic>) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_missing_command',
        'the operation must declare a command',
      );
    }
    return ProjectOperation(
      id: id,
      kind: kind,
      command: _command(commandJson),
      endpoint: json['endpoint'] == null
          ? null
          : _endpoint(_object(json['endpoint'], 'the endpoint')),
      readiness: json['readiness'] == null
          ? null
          : _readiness(_object(json['readiness'], 'the readiness')),
    );
  }

  static ProjectCommand _command(Map<String, dynamic> json) {
    _rejectUnknownKeys(json, const {
      'executable',
      'arguments',
      'workingDirectory',
      'environment',
      'timeoutMs',
    });
    final executable = json['executable'];
    if (executable is! String || executable.trim().isEmpty) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_executable',
        'the command must declare a non-empty executable',
      );
    }
    final argumentsJson = json['arguments'];
    final arguments = <String>[];
    if (argumentsJson != null) {
      if (argumentsJson is! List) {
        throw const ProjectOperationProfileFormatException(
          'project_operation_profile_invalid_arguments',
          'the command arguments must be a list of strings',
        );
      }
      for (final argument in argumentsJson) {
        if (argument is! String) {
          throw const ProjectOperationProfileFormatException(
            'project_operation_profile_invalid_arguments',
            'every command argument must be a string',
          );
        }
        arguments.add(argument);
      }
    }
    final environmentJson = json['environment'];
    final environment = <String, String>{};
    if (environmentJson != null) {
      if (environmentJson is! Map<String, dynamic>) {
        throw const ProjectOperationProfileFormatException(
          'project_operation_profile_invalid_environment',
          'the command environment must be a map of names to strings',
        );
      }
      for (final entry in environmentJson.entries) {
        final value = entry.value;
        if (value is! String) {
          throw ProjectOperationProfileFormatException(
            'project_operation_profile_invalid_environment',
            'the environment entry "${entry.key}" is not a string',
          );
        }
        environment[entry.key] = value;
      }
    }
    return ProjectCommand(
      executable: executable,
      arguments: List.unmodifiable(arguments),
      workingDirectory: json['workingDirectory'] == null
          ? const ProjectDirectory.project()
          : _directory(
              _object(json['workingDirectory'], 'the working directory'),
            ),
      environment: Map.unmodifiable(environment),
      timeout: _budget(json['timeoutMs']),
    );
  }

  static Duration _budget(Object? value) {
    if (value == null) return const Duration(minutes: 10);
    if (value is! int) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_budget',
        'the command budget must be an integer number of milliseconds',
      );
    }
    if (value <= 0) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_nonpositive_budget',
        'the command budget must be a positive number of milliseconds',
      );
    }
    if (value > maxBudget.inMilliseconds) {
      throw ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_budget',
        'the command budget is larger than the accepted bound of '
            '${maxBudget.inMilliseconds}ms',
      );
    }
    return Duration(milliseconds: value);
  }

  static ProjectDirectory _directory(Map<String, dynamic> json) {
    _rejectUnknownKeys(json, const {'kind', 'path'});
    final kindName = json['kind'];
    if (kindName is! String) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_directory_kind',
        'the working directory must declare a kind',
      );
    }
    final kind = _kindOf(ProjectDirectoryKind.values, kindName);
    if (kind == null) {
      throw ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_directory_kind',
        'the working directory kind "$kindName" is not one of '
            '${ProjectDirectoryKind.values.map((candidate) => candidate.name).join(', ')}',
      );
    }
    final path = json['path'];
    if (kind == ProjectDirectoryKind.external) {
      if (path is! String || !path.startsWith('/')) {
        throw const ProjectOperationProfileFormatException(
          'project_operation_profile_invalid_directory_path',
          'an external working directory must declare an absolute path',
        );
      }
      return ProjectDirectory.external(path);
    }
    if (path != null) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_directory_path',
        'only an external working directory may declare a path',
      );
    }
    return kind == ProjectDirectoryKind.candidate
        ? const ProjectDirectory.candidate()
        : const ProjectDirectory.project();
  }

  static ProjectEndpoint _endpoint(Map<String, dynamic> json) {
    _rejectUnknownKeys(json, const {'host', 'port', 'path'});
    final host = json['host'];
    if (host is! String || host.trim().isEmpty) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_endpoint',
        'the endpoint must declare a non-empty host',
      );
    }
    final port = json['port'];
    if (port is! int || port <= 0 || port > 65535) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_endpoint',
        'the endpoint must declare a port between 1 and 65535',
      );
    }
    final path = json['path'];
    if (path != null && (path is! String || !path.startsWith('/'))) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_endpoint',
        'the endpoint path must start with "/"',
      );
    }
    return ProjectEndpoint(
      host: host,
      port: port,
      path: path is String ? path : '/',
    );
  }

  static ProjectReadiness _readiness(Map<String, dynamic> json) {
    _rejectUnknownKeys(json, const {'kind', 'host', 'port', 'path', 'pattern'});
    final kindName = json['kind'];
    if (kindName is! String) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_readiness',
        'the readiness must declare a kind',
      );
    }
    switch (kindName) {
      case 'tcp':
        final host = json['host'];
        final port = json['port'];
        if (host is! String || host.trim().isEmpty) {
          throw const ProjectOperationProfileFormatException(
            'project_operation_profile_invalid_readiness',
            'a tcp readiness must declare a non-empty host',
          );
        }
        if (port is! int || port <= 0 || port > 65535) {
          throw const ProjectOperationProfileFormatException(
            'project_operation_profile_invalid_readiness',
            'a tcp readiness must declare a port between 1 and 65535',
          );
        }
        _rejectKeys(json, const {'kind', 'host', 'port'}, 'a tcp readiness');
        return ProjectReadiness.tcp(host: host, port: port);
      case 'logLine':
        final pattern = json['pattern'];
        if (pattern is! String || pattern.isEmpty) {
          throw const ProjectOperationProfileFormatException(
            'project_operation_profile_invalid_readiness',
            'a logLine readiness must declare a non-empty pattern',
          );
        }
        _rejectKeys(json, const {'kind', 'pattern'}, 'a logLine readiness');
        return ProjectReadiness.logLine(pattern);
      case 'filePresent':
        final path = json['path'];
        if (path is! String || path.isEmpty) {
          throw const ProjectOperationProfileFormatException(
            'project_operation_profile_invalid_readiness',
            'a filePresent readiness must declare a non-empty path',
          );
        }
        _rejectKeys(json, const {'kind', 'path'}, 'a filePresent readiness');
        return ProjectReadiness.filePresent(path);
      default:
        throw ProjectOperationProfileFormatException(
          'project_operation_profile_invalid_readiness',
          'the readiness kind "$kindName" is not one of '
              '${ProjectReadinessKind.values.map((candidate) => candidate.name).join(', ')}',
        );
    }
  }

  /// The enum member of [values] whose name is [name], or null.
  static T? _kindOf<T extends Enum>(List<T> values, String name) {
    for (final candidate in values) {
      if (candidate.name == name) return candidate;
    }
    return null;
  }

  static Map<String, String> _packageRoots(Object? value) {
    if (value == null) return const <String, String>{};
    if (value is! Map<String, dynamic>) {
      throw const ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_package_root',
        'the external package roots must be a map of names to absolute paths',
      );
    }
    final roots = <String, String>{};
    for (final entry in value.entries) {
      final target = entry.value;
      if (target is! String || !target.startsWith('/')) {
        throw ProjectOperationProfileFormatException(
          'project_operation_profile_invalid_package_root',
          'the package root "${entry.key}" must declare an absolute path',
        );
      }
      if (entry.key.isEmpty || entry.key.startsWith('/')) {
        throw ProjectOperationProfileFormatException(
          'project_operation_profile_invalid_package_root',
          'the package root "${entry.key}" must be a relative name',
        );
      }
      roots[entry.key] = target;
    }
    return Map.unmodifiable(roots);
  }

  static String _id(Map<String, dynamic> json, String key, String where) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_id',
        '$where must declare a non-empty "$key"',
      );
    }
    if (value.length > maxIdLength) {
      throw ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_id',
        '$where declares an id longer than $maxIdLength characters',
      );
    }
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value)) {
      throw ProjectOperationProfileFormatException(
        'project_operation_profile_invalid_id',
        '$where declares an id with unsupported characters',
      );
    }
    return value;
  }

  static Map<String, dynamic> _object(Object? value, String where) {
    if (value is! Map<String, dynamic>) {
      throw ProjectOperationProfileFormatException(
        'project_operation_profile_wrong_type',
        '$where must be a JSON object',
      );
    }
    return value;
  }

  static void _rejectUnknownKeys(
    Map<String, dynamic> json,
    Set<String> allowed,
  ) {
    for (final key in json.keys) {
      if (!allowed.contains(key)) {
        throw ProjectOperationProfileFormatException(
          'project_operation_profile_unknown_key',
          'the unknown key "$key" is not part of the declaration shape',
        );
      }
    }
  }

  static void _rejectKeys(
    Map<String, dynamic> json,
    Set<String> allowed,
    String where,
  ) {
    for (final key in json.keys) {
      if (!allowed.contains(key)) {
        throw ProjectOperationProfileFormatException(
          'project_operation_profile_invalid_readiness',
          '$where must not declare "$key"',
        );
      }
    }
  }
}
