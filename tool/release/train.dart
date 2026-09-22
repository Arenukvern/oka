#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

const packages = <String>[
  'oka_core',
  'oka_conformance',
  'oka_android',
  'oka_huawei',
  'oka_play',
  'oka_web',
  'oka',
];

const marker = 'x-release-please-version';

final _semver = RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$');

final class _Change {
  const _Change(this.file, this.original, this.updated);

  final File file;
  final String original;
  final String updated;
}

String _join(String first, [String? second, String? third]) {
  final parts = <String>[first];
  if (second != null) parts.add(second);
  if (third != null) parts.add(third);
  return parts.join(Platform.pathSeparator);
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _read(File file) =>
    file.readAsStringSync().replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String _replaceExactlyOnce(
  String source,
  RegExp pattern,
  String replacement,
  String error,
) {
  var count = 0;
  final result = source.replaceAllMapped(pattern, (_) {
    count++;
    return replacement;
  });
  if (count != 1) throw FormatException(error);
  return result;
}

List<_Change> _documents(Directory root, String version) {
  final changes = <_Change>[];
  final manifests = <File>[
    File(_join(root.path, 'pubspec.yaml')),
    File(_join(root.path, 'example/pubspec.yaml')),
    for (final package in packages)
      File(
        _join(
          root.path,
          'packages',
          '$package${Platform.pathSeparator}pubspec.yaml',
        ),
      ),
  ];

  final actual = <String>{};
  final packageDirectory = Directory(_join(root.path, 'packages'));
  for (final entity in packageDirectory.listSync()) {
    if (entity is! Directory) continue;
    final manifest = File(_join(entity.path, 'pubspec.yaml'));
    if (!manifest.existsSync()) continue;
    final contents = _read(manifest);
    if (!RegExp(
      r'''^publish_to:\s*["']?none''',
      multiLine: true,
    ).hasMatch(contents)) {
      actual.add(_basename(entity.path));
    }
  }
  if (actual.length != packages.length || !actual.containsAll(packages)) {
    final sorted = actual.toList()..sort();
    final inventory = sorted.map((name) => "'$name'").join(', ');
    throw FormatException('publishable inventory mismatch: [$inventory]');
  }

  final dependency = RegExp('^(  (${packages.join('|')}):)[^\\n]*\$');
  final header = RegExp('^([a-z_]+):');
  for (final file in manifests) {
    final original = _read(file);
    var updated = original;
    if (_basename(file.parent.parent.path) == 'packages') {
      updated = _replaceExactlyOnce(
        updated,
        RegExp(r'^version:[^\n]*', multiLine: true),
        'version: $version # $marker',
        '${file.path}: expected one version field',
      );
    }

    String? section;
    final sourceLines = updated.split('\n');
    final lines = <String>[];
    for (var index = 0; index < sourceLines.length; index++) {
      var line = sourceLines[index];
      final headerMatch = header.firstMatch(line);
      if (headerMatch != null) section = headerMatch.group(1);
      final dependencyMatch = dependency.firstMatch(line);
      var hasNewline = index < sourceLines.length - 1;
      if (dependencyMatch != null &&
          dependencyMatch.group(0) == line &&
          (section == 'dependencies' || section == 'dev_dependencies')) {
        final value = line.split(':').skip(1).join(':').split('#').first.trim();
        if (value.isEmpty) {
          throw FormatException(
            '${file.path}: internal dependencies must be hosted scalars',
          );
        }
        line = '${dependencyMatch.group(1)} ^$version # $marker';
        hasNewline = true;
      }
      lines.add('$line${hasNewline ? '\n' : ''}');
    }
    changes.add(_Change(file, original, lines.join()));
  }

  final versionFile = File(
    _join(
      root.path,
      'packages',
      'oka${Platform.pathSeparator}lib${Platform.pathSeparator}src${Platform.pathSeparator}version.dart',
    ),
  );
  final originalVersionSource = _read(versionFile);
  final updatedVersionSource = _replaceExactlyOnce(
    originalVersionSource,
    RegExp(r"^const String version = '[^']+';[^\n]*", multiLine: true),
    "const String version = '$version'; // $marker",
    'version.dart: expected one CLI version constant',
  );
  changes.add(
    _Change(versionFile, originalVersionSource, updatedVersionSource),
  );

  for (final relative in <String>[
    'plugin/.cursor-plugin/plugin.json',
    'plugin/.codex-plugin/plugin.json',
    'plugin/.claude-plugin/plugin.json',
    '.claude-plugin/marketplace.json',
  ]) {
    final file = File(_join(root.path, relative));
    final original = _read(file);
    final data = jsonDecode(original);
    final Map<dynamic, dynamic> target;
    if (relative.startsWith('.claude-plugin/')) {
      final plugins =
          (data as Map<String, dynamic>)['plugins'] as List<dynamic>;
      if (plugins.isEmpty) {
        throw const FormatException('RangeError: list index out of range');
      }
      target = plugins.first as Map<dynamic, dynamic>;
    } else {
      target = data as Map<dynamic, dynamic>;
    }
    if (!target.containsKey('version')) {
      throw FormatException('$relative: missing version');
    }
    final updated = target['version'] == version
        ? original
        : (() {
            target['version'] = version;
            return '${const JsonEncoder.withIndent('  ').convert(data)}\n';
          })();
    changes.add(_Change(file, original, updated));
  }
  return changes;
}

Never _usage(String? error) {
  stderr.writeln(
    'usage: train.dart [-h] [--version VERSION] {sync,check,list}',
  );
  if (error != null) stderr.writeln('train.dart: error: $error');
  exit(2);
}

({String command, String? version}) _parseArguments(List<String> arguments) {
  if (arguments.contains('-h') || arguments.contains('--help')) {
    stdout.writeln(
      'Shared release inventory and version transformations (SDK only).',
    );
    stdout.writeln();
    stdout.writeln(
      'usage: train.dart [-h] [--version VERSION] {sync,check,list}',
    );
    exit(0);
  }
  String? command;
  String? version;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--version') {
      if (++index >= arguments.length) {
        _usage('argument --version: expected one argument');
      }
      version = arguments[index];
    } else if (argument.startsWith('--version=')) {
      version = argument.substring('--version='.length);
    } else if (argument.startsWith('-')) {
      _usage('unrecognized arguments: $argument');
    } else if (command == null) {
      command = argument;
    } else {
      _usage('unrecognized arguments: $argument');
    }
  }
  if (command == null) _usage('the following arguments are required: command');
  if (!const {'sync', 'check', 'list'}.contains(command)) {
    _usage("argument command: invalid choice: '$command'");
  }
  return (command: command, version: version);
}

void main(List<String> arguments) {
  try {
    final parsed = _parseArguments(arguments);
    if (parsed.command == 'list') {
      stdout.writeln(packages.join('\n'));
      return;
    }

    final configuredRoot = Platform.environment['OKA_ROOT'];
    final root = configuredRoot == null
        ? File.fromUri(Platform.script).parent.parent.parent
        : Directory(configuredRoot);
    final versionFile = File(_join(root.path, 'VERSION'));
    final originalVersion = _read(versionFile);
    final version = parsed.version ?? originalVersion.trim();
    if (!_semver.hasMatch(version)) {
      throw FormatException("expected a plain release semver, got '$version'");
    }

    final changes = _documents(root, version)
      ..add(_Change(versionFile, originalVersion, '$version\n'));
    if (parsed.command == 'check') {
      final prefix = '${root.path}${Platform.pathSeparator}';
      final drift = <String>[];
      for (final change in changes) {
        if (change.original == change.updated) continue;
        final path = change.file.path;
        drift.add(
          path.startsWith(prefix) ? path.substring(prefix.length) : path,
        );
      }
      if (drift.isNotEmpty) {
        throw FormatException('release drift: ${drift.join(', ')}');
      }
    } else {
      for (final change in changes) {
        if (change.original != change.updated) {
          change.file.writeAsStringSync(change.updated);
        }
      }
    }
    stdout.writeln(
      '${parsed.command}_version: all release touchpoints match VERSION ($version)',
    );
  } on FileSystemException catch (error) {
    final path = error.path;
    stderr.writeln(
      'release train: ${error.message}${path == null ? '' : ': $path'}',
    );
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln('release train: ${error.message}');
    exitCode = 1;
  }
}
