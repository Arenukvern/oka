import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Stored Apple device metadata. This never invokes simctl or boots a device.
/// Kept in the CLI adapter until an Apple platform package owns this provider.
final class AppleCacheDiagnosticProvider implements CacheDiagnosticProvider {
  const AppleCacheDiagnosticProvider({
    this.readPlist = readAppleDiagnosticPlist,
  });
  final Future<Map<String, Object?>> Function(String path) readPlist;
  @override
  String get id => 'apple';

  @override
  Future<CacheDiagnosticContribution> inspect(
    CacheDiagnosticContext context,
  ) async {
    final records = <CacheDiagnosticRecord>[];
    final issues = <CacheDiagnosticIssue>[];
    for (final entry in context.storage.locations) {
      final location = entry.location;
      final device = location.category == 'apple-simulator-devices';
      if (!device && location.category != 'apple-simulator-runtimes') continue;
      final values = <String, Object?>{};
      final metadataPath = p.join(
        location.path,
        device ? 'device.plist' : 'Contents/Info.plist',
      );
      final excluded =
          await _hasLink(location.path) || await _hasLink(metadataPath);
      if (excluded) {
        issues.add(
          CacheDiagnosticIssue(
            providerId: id,
            code: 'metadata_symlink_excluded',
            message: 'Linked metadata path was not inspected.',
            path: metadataPath,
          ),
        );
      }
      final type = await FileSystemEntity.type(
        location.path,
        followLinks: false,
      );
      if (!excluded &&
          type == FileSystemEntityType.directory &&
          await FileSystemEntity.type(metadataPath, followLinks: false) ==
              FileSystemEntityType.file) {
        try {
          final raw = await readPlist(metadataPath);
          // Only public identity/configuration; no device application contents.
          for (final key
              in device
                  ? ['name', 'UDID', 'runtime', 'deviceType', 'state']
                  : [
                      'CFBundleName',
                      'CFBundleIdentifier',
                      'CFBundleShortVersionString',
                      'CFBundleVersion',
                    ]) {
            if (raw[key] is String || raw[key] is num || raw[key] is bool) {
              values[key] = raw[key];
            }
          }
        } on Object catch (error) {
          issues.add(
            CacheDiagnosticIssue(
              providerId: id,
              code: 'metadata_unreadable',
              message: error.toString(),
              path: metadataPath,
            ),
          );
        }
      }
      final kind = device ? 'simulator' : 'runtime';
      records.add(
        CacheDiagnosticRecord(
          id: CacheDiagnosticIds.resource(kind, location.path),
          kind: kind,
          label:
              (values['name'] ??
                      values['CFBundleName'] ??
                      p.basename(location.path))
                  .toString(),
          platform: 'apple',
          path: location.path,
          storagePaths: [location.path],
          metadata: {
            'identifier': values['UDID'] ?? p.basename(location.path),
            'stored_metadata': values,
            'size_bytes': entry.sizeBytes,
            'measurement_complete': entry.complete,
            'runtime_status': 'unknown',
            'metadata_available': values.isNotEmpty,
          },
          observations: [
            CacheDiagnosticObservation(
              source: CacheObservationSource.filesystem,
              status: entry.complete ? 'measured' : 'partial',
              observedAt: context.observedAt,
            ),
            CacheDiagnosticObservation(
              source: CacheObservationSource.recorded,
              status: values.isEmpty ? 'unavailable' : 'available',
              observedAt: context.observedAt,
              detail: 'Stored plist state is not a live runtime observation.',
            ),
          ],
        ),
      );
    }
    return CacheDiagnosticContribution(records: records, issues: issues);
  }
}

/// Apple's parser supports both binary and XML plists. Bounded, read-only file
/// conversion; this is not a simulator runtime probe.
Future<Map<String, Object?>> readAppleDiagnosticPlist(String path) async {
  if (!Platform.isMacOS) {
    throw UnsupportedError(
      'Apple plist decoder requires macOS; inject readPlist on other hosts.',
    );
  }
  if (await _hasLink(path) ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file ||
      await File(path).length() > 1024 * 1024) {
    throw const FormatException(
      'Plist must be a regular file of at most 1 MiB.',
    );
  }
  final process = await Process.start('/usr/bin/plutil', [
    '-convert',
    'json',
    '-o',
    '-',
    '--',
    path,
  ]);
  final output = process.stdout.transform(utf8.decoder).join();
  final error = process.stderr.transform(utf8.decoder).join();
  final timer = Timer(
    const Duration(seconds: 2),
    () => process.kill(ProcessSignal.sigkill),
  );
  try {
    final code = await process.exitCode;
    final stdout = await output;
    final stderr = await error;
    if (code != 0) throw FormatException('Cannot decode plist: $stderr');
    final decoded = jsonDecode(stdout);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Plist root must be a dictionary.');
    }
    return decoded;
  } finally {
    timer.cancel();
  }
}

Future<bool> _hasLink(String path) async {
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
