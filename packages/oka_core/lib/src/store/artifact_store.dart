import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Content-addressed identity of a stored artifact (ADR-0013).
///
/// A key is a plain value: [category] groups related artifacts (`androidx`,
/// `maven`, `kotlin-compiler`, …), [name] distinguishes artifacts inside a
/// category, [version] is the upstream version, and [contentHash] ties the
/// key to the inputs that produced it (see [ContentKey.compute]). [platform]
/// scopes artifacts whose bytes differ per platform; it is part of key
/// identity and of the on-disk path.
///
/// [toString] is human-decodable and equals [relativePath] — the store
/// layout mirrors it one-to-one, e.g.
/// `aapt2/aapt2/8.0.2-3f9d2c1a8b77/linux`.
@immutable
class ContentKey {
  const ContentKey({
    required this.category,
    required this.name,
    required this.version,
    required this.contentHash,
    this.platform = 'any',
    this.fileName,
  });

  /// Derives the content hash from [inputs] (full sha256 hex).
  ///
  /// Inputs are anything that determines the artifact bytes: download URL,
  /// tool version pins, generator versions. The input list is order-
  /// insensitive (sorted before hashing). Same inputs → same hash → cache
  /// hit; any change → new key, never silent reuse. Include [platform] in
  /// [inputs] when artifact bytes differ per platform.
  factory ContentKey.compute({
    required final String category,
    required final String name,
    required final String version,
    required final List<String> inputs,
    final String platform = 'any',
    final String? fileName,
  }) {
    final material = [...inputs]..sort();
    final digest =
        sha256.convert(utf8.encode(material.join('\x00'))).toString();
    return ContentKey(
      category: category,
      name: name,
      version: version,
      contentHash: digest,
      platform: platform,
      fileName: fileName,
    );
  }

  /// Group of related artifacts, e.g. `'androidx'`, `'maven'`, `'tools'`.
  final String category;

  /// Artifact name inside the category, e.g. `'annotation'`.
  final String name;

  /// Upstream version string, e.g. `'1.9.1'`.
  final String version;

  /// Content hash (sha256 hex) binding the key to its producing inputs.
  final String contentHash;

  /// Platform the artifact is for (`'linux'`, `'jvm'`, `'any'`, …).
  final String platform;

  /// File name used inside the store directory; defaults to [name]. Not an
  /// identity field: the same content under a different file name is the
  /// same artifact.
  final String? fileName;

  /// First 12 hex chars of [contentHash] — the human-decodable form used in
  /// directory names and printed keys.
  String get shortHash => contentHash.length <= 12
      ? contentHash
      : contentHash.substring(0, 12);

  /// Directory name under `<category>/<name>/`: `<version>-<hash>`.
  String get dirName => '$version-$shortHash';

  /// Store-relative directory path — also the [toString] form, so `oka cache
  /// why` output and `ls` output agree character for character.
  String get relativePath => '$category/$name/$dirName/$platform';

  /// File name materialized inside the store directory.
  String get fileNameOrDefault => fileName ?? name;

  /// Stable store identifier.
  String get id => relativePath;

  /// Debug string: the store-relative path (same as [id]).
  @override
  String toString() => relativePath;

  @override
  bool operator ==(final Object other) =>
      other is ContentKey &&
      other.category == category &&
      other.name == name &&
      other.version == version &&
      other.contentHash == contentHash &&
      other.platform == platform;

  /// Hash over all key fields (equality is field-wise).
  @override
  int get hashCode =>
      Object.hash(category, name, version, contentHash, platform);
}

/// One materialized artifact in a store: its [ContentKey], where it lives on
/// disk, how big it is, when it was created, and which component registered
/// it (`source`, e.g. `maven-resolver`).
@immutable
class ArtifactStoreEntry {
  const ArtifactStoreEntry({
    required this.key,
    required this.path,
    required this.sizeBytes,
    required this.createdAt,
    this.source,
    this.sweepDir,
  });

  /// The content key addressing this entry.
  final ContentKey key;

  /// Absolute path of the artifact file on disk.
  final String path;

  /// Size of the artifact file in bytes.
  final int sizeBytes;

  /// When the artifact entered the store — the gc age input.
  final DateTime createdAt;

  /// Component that registered the entry, when known.
  final String? source;

  /// Directory removed on delete/purge. Foreign-layout entries (e.g. Maven's
  /// `group/artifact/version` dirs) sweep their whole version dir; plain
  /// entries sweep the key's own platform dir.
  final String? sweepDir;

  /// Directory containing the artifact — the unit `delete`/`purge` removes.
  String get dir => sweepDir ?? p.dirname(path);
}

/// Outcome of a [ArtifactStore.purge] run.
@immutable
class PurgeResult {
  const PurgeResult({required this.deleted, required this.bytesFreed});

  /// Number of entries removed (or that would be removed, on a dry run).
  final int deleted;

  /// Bytes reclaimed (or reclaimable, on a dry run).
  final int bytesFreed;
}

/// The one primitive for shared **inputs** across projects (ADR-0013): SDK
/// components, Maven jars, Kotlin compilers, emulator images. Per-project
/// **outputs** (staged APKs, dex) stay in `buildDir/` under step-cache
/// fingerprints — outputs are where nondeterminism lives; inputs are what a
/// store can safely share (`OKA_CACHE` may point at a team/network path).
///
/// The Dart API is the real agent surface: implementations must be
/// inspectable ([entries]), addressable ([find]), purgeable ([delete],
/// [purge]), and fetch through a single method — no opaque blobs, no
/// interactive prompts, no stdin in any build path (ADR-0007).
abstract interface class ArtifactStore {
  /// Returns the stored file for [key], materializing it via [miss] on
  /// first use. The [miss] closure produces the artifact (download, extract,
  /// generate); the store decides where it lives. Hits must not re-run
  /// [miss]; hand-deleted files are re-fetched, never silently reused.
  Future<File> fetch(final ContentKey key, final Future<File> Function() miss);

  /// Returns the stored entry for [key], or null when absent.
  Future<ArtifactStoreEntry?> find(final ContentKey key);

  /// All entries currently in the store.
  Future<List<ArtifactStoreEntry>> entries();

  /// Deletes the entry for [key] (file + index). Returns true when
  /// something was removed.
  Future<bool> delete(final ContentKey key);

  /// Bulk deletion by explicit criteria only — never interactive:
  /// [olderThan] removes entries created before the cutoff; [maxTotalBytes]
  /// evicts oldest-first until the store fits the budget; [category]
  /// narrows both. [dryRun] reports without deleting.
  Future<PurgeResult> purge({
    final Duration? olderThan,
    final int? maxTotalBytes,
    final String? category,
    final bool dryRun = false,
  });
}

/// Default [ArtifactStore]: a plain directory tree with one small JSON index
/// per entry — no sqlite, no opaque blobs. A human can `ls`, `du`, and
/// `find -delete` it, and every artifact is where [ContentKey.toString]
/// says it is:
///
/// ```
/// <root>/<category>/<name>/<version>-<hash12>/<platform>/<fileName>
/// <root>/<category>/<name>/<version>-<hash12>/<platform>/oka_store.json
///
/// e.g. ~/.oka/store/androidx/annotation/1.9.1-3f9d2c1a8b77/
///      any/annotation-jvm-1.9.1.jar
/// ```
///
/// The root defaults to `~/.oka/store` and honors the `OKA_CACHE` env var
/// (team/network sharing, per-project overrides).
///
/// External producers with their own human-decodable layout (the Maven
/// resolver's `group/artifact/version` tree) participate by dropping an
/// [indexFileName] JSON next to their artifact; [entries] and [find]
/// discover those, and delete/purge sweep the producer's version dir.
class LocalArtifactStore implements ArtifactStore {
  LocalArtifactStore({final String? root, final Map<String, String>? environment})
      : root = root ?? defaultRoot(environment: environment);

  /// Store root directory. All artifacts live under it.
  final String root;

  /// Name of the per-entry index file every store participant writes.
  static const indexFileName = 'oka_store.json';

  /// Resolves the store root: `OKA_CACHE` when set (supports `~/`), else
  /// `~/.oka/store`. [environment] defaults to `Platform.environment` and is
  /// injectable for tests.
  static String defaultRoot({final Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final home =
        env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;
    final override = env['OKA_CACHE']?.trim();
    if (override != null && override.isNotEmpty) {
      final expanded = override.startsWith('~')
          ? p.join(home, override.substring(1))
          : override;
      return p.normalize(expanded);
    }
    return p.join(home, '.oka', 'store');
  }

  Directory _entryDir(final ContentKey key) => Directory(
        p.join(root, key.category, key.name, key.dirName, key.platform),
      );

  /// Reads a per-entry index; null when missing or corrupt (corrupt indexes
  /// are skipped, never fatal — the entry is simply re-fetchable).
  Map<String, dynamic>? _readIndexAt(final String dirPath) {
    final f = File(p.join(dirPath, indexFileName));
    if (!f.existsSync()) return null;
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> _entryJson(
    final ContentKey key,
    final String fileName,
    final int sizeBytes, {
    final String? source,
  }) =>
      {
        'category': key.category,
        'name': key.name,
        'version': key.version,
        'hash': key.contentHash,
        'platform': key.platform,
        'file': fileName,
        'size_bytes': sizeBytes,
        'created': DateTime.now().toUtc().toIso8601String(),
        'source': ?source,
      };

  /// Turns a per-entry index (written by [fetch] or by a foreign producer)
  /// into an entry. Throws [FormatException] when the record is malformed.
  ArtifactStoreEntry _entryFromIndex(
    final Map<String, dynamic> json,
    final String indexDirPath,
  ) {
    final fileName = (json['file'] ?? json['path']) as String?;
    if (fileName == null) {
      throw const FormatException('index lacks artifact file name');
    }
    final artifact = File(p.join(indexDirPath, fileName));
    return ArtifactStoreEntry(
      key: ContentKey(
        category: json['category'] as String,
        name: json['name'] as String,
        version: json['version'] as String,
        contentHash: json['hash'] as String,
        platform: json['platform'] as String? ?? 'any',
        fileName: fileName,
      ),
      path: artifact.path,
      sizeBytes: json['size_bytes'] as int? ?? artifact.lengthSync(),
      createdAt: DateTime.tryParse(json['created'] as String? ?? '') ??
          artifact.statSync().modified.toUtc(),
      source: json['source'] as String?,
      sweepDir: json['sweepDir'] as String? ?? indexDirPath,
    );
  }

  @override
  Future<File> fetch(
    final ContentKey key,
    final Future<File> Function() miss,
  ) async {
    final dirPath = _entryDir(key).path;
    final index = _readIndexAt(dirPath);
    if (index != null) {
      final stored = File(p.join(dirPath, index['file'] as String? ?? ''));
      if (await stored.exists()) {
        return stored; // hit — miss never runs
      }
    }

    final produced = await miss();
    final destDir = Directory(dirPath);
    await destDir.create(recursive: true);
    final destName = key.fileName ?? p.basename(produced.path);
    final dest = File(p.join(dirPath, destName));
    if (p.canonicalize(produced.path) != p.canonicalize(dest.path)) {
      await produced.copy(dest.path);
    }
    File(p.join(dirPath, indexFileName)).writeAsStringSync(
      const JsonEncoder.withIndent('  ')
          .convert(_entryJson(key, destName, await dest.length())),
      flush: true,
    );
    return dest;
  }

  /// Looks up [key] via its own directory index first, then (for
  /// foreign-layout entries like Maven's version dirs) by scanning
  /// discovered entries. Null when absent.
  @override
  Future<ArtifactStoreEntry?> find(final ContentKey key) async {
    // Fast path: the key addresses its own directory.
    final dirPath = _entryDir(key).path;
    final index = _readIndexAt(dirPath);
    if (index != null) {
      final stored = File(p.join(dirPath, index['file'] as String? ?? ''));
      if (await stored.exists()) return _entryFromIndex(index, dirPath);
      return null;
    }
    // Foreign-layout entries (e.g. Maven's version dirs) live off the key's
    // own path — match them among the discovered entries.
    for (final entry in await entries()) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  /// Discovers all indexed entries under [root] (by walking
  /// [indexFileName] files); empty when the store does not exist.
  @override
  Future<List<ArtifactStoreEntry>> entries() async {
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return const [];
    final out = <ArtifactStoreEntry>[];
    final seen = <String>{};
    await for (final entity
        in rootDir.list(recursive: true, followLinks: false)) {
      if (entity is! File || p.basename(entity.path) != indexFileName) {
        continue;
      }
      try {
        final json = jsonDecode(entity.readAsStringSync());
        if (json is! Map<String, dynamic>) continue;
        final entry = _entryFromIndex(json, p.dirname(entity.path));
        if (seen.contains(entry.key.id)) continue;
        if (!File(entry.path).existsSync()) continue; // stale index
        out.add(entry);
        seen.add(entry.key.id);
      } on FormatException {
        continue; // corrupt index — skip, never fatal
      } on FileSystemException {
        continue;
      }
    }
    out.sort((final a, final b) => a.key.id.compareTo(b.key.id));
    return out;
  }

  /// Removes an entry's sweep dir and prunes now-empty parents up to (but
  /// never including) the store root, so purged categories leave no
  /// skeleton behind.
  Future<bool> _removeSweepDir(final ArtifactStoreEntry entry) async {
    final dir = Directory(entry.dir);
    if (!await dir.exists()) return false;
    await dir.delete(recursive: true);

    var current = p.canonicalize(p.dirname(dir.path));
    final rootPath = p.canonicalize(root);
    while (p.isWithin(rootPath, current)) {
      final d = Directory(current);
      if (!d.existsSync()) {
        current = p.dirname(current);
        continue;
      }
      if (d.listSync(followLinks: false).isNotEmpty) break;
      try {
        await d.delete();
      } on FileSystemException {
        break;
      }
      current = p.dirname(current);
    }
    return true;
  }

  /// Deletes the entry addressed by [key] (its sweep directory); `false`
  /// when the key is unknown.
  @override
  Future<bool> delete(final ContentKey key) async {
    final entry = await find(key);
    if (entry == null) return false;
    return _removeSweepDir(entry);
  }

  @override
  Future<PurgeResult> purge({
    final Duration? olderThan,
    final int? maxTotalBytes,
    final String? category,
    final bool dryRun = false,
  }) async {
    var all = await entries();
    if (category != null) {
      all = all.where((final e) => e.key.category == category).toList();
    }
    // Oldest first: deterministic eviction order.
    all.sort((final a, final b) => a.createdAt.compareTo(b.createdAt));

    // Age criterion: everything created before the cutoff goes.
    final cutoff = olderThan == null
        ? null
        : DateTime.now().toUtc().subtract(olderThan);
    final victims = <ArtifactStoreEntry>[
      if (cutoff != null)
        for (final e in all)
          if (e.createdAt.isBefore(cutoff)) e,
    ];

    // Size criterion: evict oldest-first until the remainder fits the
    // budget (entries already removed by age don't count against it).
    if (maxTotalBytes != null) {
      var budgetTotal =
          all.fold<int>(0, (final s, final e) => s + e.sizeBytes) -
              victims.fold<int>(0, (final s, final e) => s + e.sizeBytes);
      for (final e in all) {
        if (budgetTotal <= maxTotalBytes) break;
        if (victims.contains(e)) continue;
        victims.add(e);
        budgetTotal -= e.sizeBytes;
      }
    }

    var freed = 0;
    for (final v in victims) {
      freed += v.sizeBytes;
      if (!dryRun) await _removeSweepDir(v);
    }
    return PurgeResult(deleted: victims.length, bytesFreed: freed);
  }
}
