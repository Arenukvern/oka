import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Describes Android virtual devices from recorded AVD metadata and the
/// locations already discovered by the cache workspace.
///
/// This provider deliberately does not run adb, emulator, or avdmanager. A
/// device's running state is not inferred from its files.
final class AndroidCacheDiagnosticProvider implements CacheDiagnosticProvider {
  const AndroidCacheDiagnosticProvider();

  @override
  String get id => 'android';

  @override
  Future<CacheDiagnosticContribution> inspect(
    CacheDiagnosticContext context,
  ) async {
    final issues = <CacheDiagnosticIssue>[];
    final roots = <String, _AvdSource>{};
    for (final location in context.storage.locations.where(
      (entry) => entry.location.category == 'android-virtual-device',
    )) {
      final path = p.normalize(p.absolute(location.location.path));
      try {
        if (await _hasSymlink(path)) {
          issues.add(
            _issue(
              'symlink_metadata',
              'AVD metadata path contains a symbolic link.',
              path,
            ),
          );
          continue;
        }
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.directory &&
            p.basename(path).endsWith('.avd')) {
          roots.putIfAbsent(path, () => _AvdSource(path: path));
        } else if (type == FileSystemEntityType.file && path.endsWith('.ini')) {
          final values = await _readIni(File(path));
          final pointed = values['path'];
          if (pointed == null || pointed.trim().isEmpty) {
            issues.add(
              _issue('malformed_metadata', 'AVD ini has no path.', path),
            );
            continue;
          }
          final avdPath = p.normalize(
            p.isAbsolute(pointed.trim())
                ? pointed.trim()
                : p.join(p.dirname(path), pointed.trim()),
          );
          if (await _hasSymlink(avdPath)) {
            issues.add(
              _issue(
                'symlink_metadata',
                'AVD path contains a symbolic link.',
                avdPath,
              ),
            );
            continue;
          }
          roots.update(
            avdPath,
            (source) => source..iniFiles.add(path),
            ifAbsent: () => _AvdSource(path: avdPath, iniFiles: [path]),
          );
          roots[avdPath]!.topLevelValues.addAll(values);
        }
      } on FormatException catch (error) {
        issues.add(_issue('malformed_metadata', error.message, path));
      } on FileSystemException catch (error) {
        issues.add(_issue('unreadable_metadata', error.message, path));
      }
    }

    final records = <CacheDiagnosticRecord>[];
    for (final source in roots.values) {
      final parsed = await _inspectAvd(source, context, issues);
      if (parsed != null) records.add(parsed);
    }
    return CacheDiagnosticContribution(records: records, issues: issues);
  }

  Future<CacheDiagnosticRecord?> _inspectAvd(
    _AvdSource source,
    CacheDiagnosticContext context,
    List<CacheDiagnosticIssue> issues,
  ) async {
    final path = source.path;
    final missing =
        await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.notFound;
    final config = File(p.join(path, 'config.ini'));
    final values = <String, String>{...source.topLevelValues};
    if (await _hasSymlink(config.path)) {
      issues.add(
        _issue(
          'symlink_metadata',
          'AVD config.ini contains a symbolic link.',
          config.path,
        ),
      );
    } else if (await config.exists()) {
      try {
        values.addAll(await _readIni(config));
      } on FormatException catch (error) {
        issues.add(_issue('malformed_metadata', error.message, config.path));
      } on FileSystemException catch (error) {
        issues.add(_issue('unreadable_metadata', error.message, config.path));
      }
    } else {
      issues.add(
        _issue('missing_metadata', 'AVD config.ini is missing.', config.path),
      );
    }

    final name =
        _first(values, const [
          'avd.ini.displayname',
          'displayname',
          'hw.device.name',
        ]) ??
        p.basenameWithoutExtension(path);
    final api = _apiLevel(values);
    final abi =
        _first(values, const ['abi.type', 'abi']) ?? _abiFromImage(values);
    final image =
        _first(values, const ['image.sysdir.1', 'system-image', 'image']) ??
        _targetImage(values);
    final avdId =
        _first(source.topLevelValues, const ['avd']) ??
        p.basenameWithoutExtension(
          source.iniFiles.isEmpty ? path : source.iniFiles.first,
        );
    final deviceName = _first(values, const ['hw.device.name']);
    final storagePaths = <String>[];
    final metadata = <String, Object?>{
      'avd_id': avdId,
      'runtime_status': 'unknown',
    };
    if (deviceName != null) metadata['device_name'] = deviceName;
    if (name.isNotEmpty) metadata['display_name'] = name;
    if (api != null) metadata['api_level'] = api;
    if (abi != null) metadata['abi'] = abi;
    if (image != null) metadata['system_image'] = image;

    final components = <String, Map<String, Object?>>{};
    for (final component in const [
      'userdata-qemu.img',
      'userdata.img',
      'snapshots',
    ]) {
      final componentPath = p.join(path, component);
      final measured = await _measure(componentPath, component, issues);
      if (measured != null) {
        storagePaths.add(componentPath);
        components[component] = measured;
        if (measured['complete'] == false) {
          issues.add(
            _issue(
              'incomplete_storage',
              '$component measurement was incomplete: '
                  '${(measured['warnings'] as List<Object?>? ?? const []).join('; ')}',
              componentPath,
            ),
          );
        }
      }
    }
    if (components.isNotEmpty) metadata['storage'] = components;

    final related = <String>[];
    for (final project in context.projects) {
      related.addAll(
        await _linkedSessions(project, {
          name,
          avdId,
          p.basenameWithoutExtension(path),
        }, issues),
      );
    }
    final id = CacheDiagnosticIds.resource('emulator', path);
    return CacheDiagnosticRecord(
      id: id,
      kind: 'emulator',
      label: name,
      platform: 'android',
      path: path,
      storagePaths: storagePaths,
      relatedIds: related,
      metadata: metadata,
      observations: [
        CacheDiagnosticObservation(
          source: CacheObservationSource.filesystem,
          status: missing ? 'missing_directory' : 'recorded_metadata',
          observedAt: context.observedAt,
          detail: 'AVD metadata and component sizes were read from disk.',
        ),
      ],
    );
  }

  Future<Map<String, Object?>?> _measure(
    String path,
    String name,
    List<CacheDiagnosticIssue> issues,
  ) async {
    try {
      final report = await StorageInventory(
        locations: [
          StorageLocation(
            id: 'android-avd-$name',
            path: path,
            category: 'android-avd-component',
            platform: 'android',
            ownership: 'descriptive',
            prunable: false,
          ),
        ],
      ).scan();
      if (report.locations.isEmpty) return null;
      final measurement = report.locations.single;
      return {
        'path': path,
        'size_bytes': measurement.sizeBytes,
        'file_count': measurement.fileCount,
        'complete': measurement.complete,
        if (measurement.warnings.isNotEmpty) 'warnings': measurement.warnings,
      };
    } on FileSystemException catch (error) {
      issues.add(_issue('unreadable_storage', error.message, path));
      return null;
    }
  }

  Future<List<String>> _linkedSessions(
    String project,
    Set<String> avds,
    List<CacheDiagnosticIssue> issues,
  ) async {
    final directory = Directory(p.absolute(project, '.oka_cache', 'processes'));
    if (!await directory.exists()) return const [];
    final links = <String>[];
    try {
      // Registry inspection is intentionally silent and returns parse issues.
      final snapshot = await ProcessLeaseRegistry(directory).inspect();
      for (final lease in snapshot.leases) {
        if (avds.contains(lease.identity['avd'])) {
          links.add(CacheDiagnosticIds.session(project, lease.id));
        }
      }
      issues.addAll(
        snapshot.issues.map(
          (issue) => _issue('malformed_lease', issue.message, issue.path),
        ),
      );
    } on FileSystemException catch (error) {
      issues.add(
        _issue('unreadable_lease_registry', error.message, directory.path),
      );
    }
    return links..sort();
  }

  static Future<Map<String, String>> _readIni(File file) async {
    final values = <String, String>{};
    for (final raw in await file.readAsLines()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      final separator = line.indexOf('=');
      if (separator <= 0) throw FormatException('Invalid INI line: $line');
      values[line.substring(0, separator).trim()] = line
          .substring(separator + 1)
          .trim();
    }
    return values;
  }

  static String? _first(Map<String, String> values, List<String> keys) {
    for (final key in keys) {
      final value = values[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static int? _apiLevel(Map<String, String> values) {
    final raw = _first(values, const [
      'target',
      'api.level',
      'api-level',
      'image.sysdir.1',
    ]);
    if (raw == null) return null;
    final match = RegExp(
      r'(?:android-|API[- ]?)(\d+)',
      caseSensitive: false,
    ).firstMatch(raw);
    return int.tryParse(match?.group(1) ?? raw);
  }

  static String? _abiFromImage(Map<String, String> values) =>
      _first(values, const ['image.sysdir.1'])
          ?.split('/')
          .lastWhere(
            (part) =>
                part.contains('x86') ||
                part.contains('arm') ||
                part.contains('mips'),
            orElse: () => '',
          );

  static String? _targetImage(Map<String, String> values) =>
      _first(values, const ['target']);

  static CacheDiagnosticIssue _issue(
    String code,
    String message,
    String path,
  ) => CacheDiagnosticIssue(
    providerId: 'android',
    code: code,
    message: message,
    path: path,
  );

  static Future<bool> _hasSymlink(String path) async {
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
}

final class _AvdSource {
  _AvdSource({required this.path, List<String>? iniFiles})
    : iniFiles = iniFiles ?? <String>[];
  final String path;
  final List<String> iniFiles;
  final topLevelValues = <String, String>{};
}
