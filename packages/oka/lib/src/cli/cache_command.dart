/// `oka cache` — inspectable views over the shared artifact store (ADR-0013).
///
/// IMPORTANT (integration wiring): bin/oka.dart must register this command.
/// The integrator should add the exact switch case below next to the other
/// command cases (and import `package:oka/src/cli/cache_command.dart`):
///
/// ```dart
/// case 'cache':
///   await CacheCommand().run(commandArgs);
/// ```
///
/// Subcommands (views over [ArtifactStore] — the Dart API is the agent
/// surface, these are conveniences for humans):
///
/// * `oka cache list [--json]` — table of all store entries.
/// * `oka cache gc --older-than=<n>d|h|m [--max-size=<N>[K|M|G]] [--dry-run]`
///   — purge by explicit criteria only; never interactive.
/// * `oka cache why <category[/name[/version]]>` — which key/path a given
///   artifact maps to.
library;

import 'dart:convert';

import 'package:args/args.dart';
import 'package:oka_core/oka_core.dart';

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
  })  : _out = out ?? print,
        _store = store ?? LocalArtifactStore();
  final void Function(String message) _out;
  final LocalArtifactStore _store;

  Future<void> run(final List<String> args) async {
    if (args.isEmpty) {
      _printUsage();
      throw const CacheCommandError(64, 'oka cache: usage error'); // tests assert the typed error
    }
    final subcommand = args.first;
    final rest = args.skip(1).toList();
    switch (subcommand) {
      case 'list':
        await _list(rest);
      case 'gc':
        await _gc(rest);
      case 'why':
        await _why(rest);
      default:
        _out('Unknown cache subcommand: $subcommand');
        _printUsage();
        throw const CacheCommandError(64, 'oka cache: usage error');
    }
  }

  Future<void> _list(final List<String> args) async {
    final parser = ArgParser()
      ..addFlag('json', negatable: false, help: 'Machine-readable JSON output');
    final results = parser.parse(args);
    final store = _store;
    final entries = await store.entries();

    if (results['json'] as bool) {
      _out(
        const JsonEncoder.withIndent('  ').convert([
          for (final e in entries)
            {
              'category': e.key.category,
              'name': e.key.name,
              'version': e.key.version,
              'hash': e.key.contentHash,
              'platform': e.key.platform,
              'size_bytes': e.sizeBytes,
              'created': e.createdAt.toIso8601String(),
              'path': e.path,
            },
        ]),
      );
      return;
    }

    if (entries.isEmpty) {
      _out('Cache store is empty: ${store.root}');
      return;
    }

    _out('Artifact store: ${store.root}\n');
    _out(
      '${_pad('CATEGORY', 18)}'
      '${_pad('NAME', 32)}'
      '${_pad('VERSION', 14)}'
      '${_pad('PLATFORM', 10)}'
      '${_pad('SIZE', 10)}'
      'CREATED',
    );
    var totalBytes = 0;
    for (final e in entries) {
      totalBytes += e.sizeBytes;
      _out(
        '${_pad(e.key.category, 18)}'
        '${_pad(e.key.name, 32)}'
        '${_pad(e.key.version, 14)}'
        '${_pad(e.key.platform, 10)}'
        '${_pad(_formatBytes(e.sizeBytes), 10)}'
        '${_formatDate(e.createdAt)}',
      );
    }
    _out('\n${entries.length} entries, ${_formatBytes(totalBytes)} total');
  }

  Future<void> _gc(final List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'older-than',
        help: 'Remove entries older than this, e.g. 30d, 12h, 45m',
      )
      ..addOption(
        'max-size',
        help: 'Evict oldest entries until the store fits this budget, '
            'e.g. 500MB, 2GB, 1048576',
      )
      ..addFlag('dry-run', negatable: false, help: 'Show what would be purged');
    final results = parser.parse(args);

    // Explicit criteria only — never interactive.
    final olderThanRaw = results['older-than'] as String?;
    final maxSizeRaw = results['max-size'] as String?;
    if (olderThanRaw == null && maxSizeRaw == null) {
      _out('Refusing to gc without explicit criteria.\n');
      _out(parser.usage);
      throw const CacheCommandError(64, 'oka cache: usage error');
    }

    Duration? olderThan;
    if (olderThanRaw != null) {
      olderThan = _parseDuration(olderThanRaw);
      if (olderThan == null) {
        _out(
          'Invalid --older-than value: $olderThanRaw (expected e.g. 30d, 12h, 45m)',
        );
        throw const CacheCommandError(64, 'oka cache: usage error');
      }
    }

    int? maxTotalBytes;
    if (maxSizeRaw != null) {
      maxTotalBytes = _parseSize(maxSizeRaw);
      if (maxTotalBytes == null) {
        _out(
          'Invalid --max-size value: $maxSizeRaw (expected e.g. 500MB, 2GB, 1048576)',
        );
        throw const CacheCommandError(64, 'oka cache: usage error');
      }
    }

    final store = _store;
    final dryRun = results['dry-run'] as bool;
    final result = await store.purge(
      olderThan: olderThan,
      maxTotalBytes: maxTotalBytes,
      dryRun: dryRun,
    );
    _out(
      '${dryRun ? 'Would purge' : 'Purged'} ${result.deleted} entries, '
      '${_formatBytes(result.bytesFreed)} '
      '${dryRun ? 'reclaimable' : 'freed'} from ${store.root}',
    );
  }

  Future<void> _why(final List<String> args) async {
    if (args.isEmpty) {
      _out(
        'Usage: oka cache why <category[/name[/version]]>\n'
        'Example: oka cache why androidx/annotation-jvm/1.9.1',
      );
      throw const CacheCommandError(64, 'oka cache: usage error');
    }
    final parts = args.first.split('/');
    final store = _store;
    final entries = await store.entries();
    final matches = entries.where((final e) {
      if (parts.isNotEmpty && e.key.category != parts[0]) return false;
      if (parts.length > 1 && e.key.name != parts[1]) return false;
      if (parts.length > 2 && e.key.version != parts[2]) return false;
      return true;
    }).toList();

    if (matches.isEmpty) {
      _out('No store entry matches "${args.first}".');
      _out('Store root: ${store.root}');
      throw const CacheCommandError(1, 'no store entry matches');
    }

    for (final e in matches) {
      _out('${e.key}'); // human-decodable: category/name/version-hash/platform
      _out('  path:     ${e.path}');
      _out('  size:     ${_formatBytes(e.sizeBytes)}');
      _out('  created:  ${_formatDate(e.createdAt)}');
    }
  }

  void _printUsage() {
    _out('Usage: oka cache <list|gc|why>');
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

  Duration? _parseDuration(final String raw) {
    final m = RegExp(r'^(\d+)([dhm])$').firstMatch(raw.trim());
    if (m == null) return null;
    final n = int.parse(m.group(1)!);
    switch (m.group(2)) {
      case 'd':
        return Duration(days: n);
      case 'h':
        return Duration(hours: n);
      case 'm':
        return Duration(minutes: n);
    }
    return null;
  }

  /// Parses plain bytes or K/M/G suffixed sizes (binary multiples).
  int? _parseSize(final String raw) {
    final m = RegExp(r'^(\d+)([KMGT])?$', caseSensitive: false)
        .firstMatch(raw.trim());
    if (m == null) return null;
    var value = int.parse(m.group(1)!);
    switch (m.group(2)?.toUpperCase()) {
      case 'K':
        value *= 1024;
      case 'M':
        value *= 1024 * 1024;
      case 'G':
        value *= 1024 * 1024 * 1024;
      case 'T':
        value *= 1024 * 1024 * 1024 * 1024;
    }
    return value;
  }

  String _pad(final String s, final int width) {
    if (s.length >= width) return '$s ';
    return s.padRight(width);
  }

  String _formatBytes(final int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatDate(final DateTime dt) {
    final local = dt.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
