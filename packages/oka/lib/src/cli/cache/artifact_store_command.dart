import 'dart:convert';

import 'package:args/args.dart';
import 'package:oka_core/oka_core.dart';

import 'parsers.dart';

final class ArtifactStoreCommand {
  const ArtifactStoreCommand({
    required this.store,
    required this.out,
    required this.usageError,
  });

  final LocalArtifactStore store;
  final void Function(String) out;
  final Exception Function(int exitCode, String message) usageError;

  Future<void> list(List<String> args) async {
    final parser = ArgParser()
      ..addFlag('json', negatable: false, help: 'Machine-readable JSON output');
    final results = parser.parse(args);
    final entries = await store.entries();
    if (results['json'] as bool) {
      out(
        const JsonEncoder.withIndent('  ').convert([
          for (final entry in entries)
            {
              'category': entry.key.category,
              'name': entry.key.name,
              'version': entry.key.version,
              'hash': entry.key.contentHash,
              'platform': entry.key.platform,
              'size_bytes': entry.sizeBytes,
              'created': entry.createdAt.toIso8601String(),
              'path': entry.path,
            },
        ]),
      );
      return;
    }
    if (entries.isEmpty) {
      out('Cache store is empty: ${store.root}');
      return;
    }
    out('Artifact store: ${store.root}\n');
    out(
      '${_pad('CATEGORY', 18)}${_pad('NAME', 32)}${_pad('VERSION', 14)}'
      '${_pad('PLATFORM', 10)}${_pad('SIZE', 10)}CREATED',
    );
    var totalBytes = 0;
    for (final entry in entries) {
      totalBytes += entry.sizeBytes;
      out(
        '${_pad(entry.key.category, 18)}${_pad(entry.key.name, 32)}'
        '${_pad(entry.key.version, 14)}${_pad(entry.key.platform, 10)}'
        '${_pad(formatBytes(entry.sizeBytes), 10)}${_formatDate(entry.createdAt)}',
      );
    }
    out('\n${entries.length} entries, ${formatBytes(totalBytes)} total');
  }

  Future<void> gc(List<String> args) async {
    final parser = ArgParser()
      ..addOption('older-than', help: 'Remove entries older than this')
      ..addOption('max-size', help: 'Evict oldest entries to this budget')
      ..addFlag('dry-run', negatable: false, help: 'Show what would be purged');
    final results = parser.parse(args);
    final age = results['older-than'] as String?;
    final size = results['max-size'] as String?;
    if (age == null && size == null) {
      out('Refusing to gc without explicit criteria.\n');
      out(parser.usage);
      throw usageError(64, 'oka cache: usage error');
    }
    final olderThan = age == null ? null : parseCacheDuration(age);
    final maxBytes = size == null ? null : parseCacheSize(size);
    if (age != null && olderThan == null) {
      out('Invalid --older-than value: $age (expected e.g. 30d, 12h, 45m)');
      throw usageError(64, 'oka cache: usage error');
    }
    if (size != null && maxBytes == null) {
      out(
        'Invalid --max-size value: $size (expected e.g. 500MB, 2GB, 1048576)',
      );
      throw usageError(64, 'oka cache: usage error');
    }
    final dryRun = results['dry-run'] as bool;
    final result = await store.purge(
      olderThan: olderThan,
      maxTotalBytes: maxBytes,
      dryRun: dryRun,
    );
    out(
      '${dryRun ? 'Would purge' : 'Purged'} ${result.deleted} entries, '
      '${formatBytes(result.bytesFreed)} ${dryRun ? 'reclaimable' : 'freed'} from ${store.root}',
    );
  }

  Future<void> why(List<String> args) async {
    if (args.isEmpty) {
      out(
        'Usage: oka cache why <category[/name[/version]]>\n'
        'Example: oka cache why androidx/annotation-jvm/1.9.1',
      );
      throw usageError(64, 'oka cache: usage error');
    }
    final parts = args.first.split('/');
    final matches = (await store.entries()).where((entry) {
      if (entry.key.category != parts[0]) return false;
      if (parts.length > 1 && entry.key.name != parts[1]) return false;
      return parts.length <= 2 || entry.key.version == parts[2];
    }).toList();
    if (matches.isEmpty) {
      out('No store entry matches "${args.first}".');
      out('Store root: ${store.root}');
      throw usageError(1, 'no store entry matches');
    }
    for (final entry in matches) {
      out('${entry.key}');
      out('  path:     ${entry.path}');
      out('  size:     ${formatBytes(entry.sizeBytes)}');
      out('  created:  ${_formatDate(entry.createdAt)}');
    }
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _pad(String value, int width) =>
    value.length >= width ? '$value ' : value.padRight(width);

String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
