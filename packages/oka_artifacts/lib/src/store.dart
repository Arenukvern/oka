/// The content-addressed artifact store (ADR-0043 decisions 2–3).
///
/// Layout under [ArtifactStore.root] (default `~/.oka/artifacts`, always
/// outside the visible codebase):
///
/// ```
/// blobs/<sha256>                full snapshots, deduped by hash
/// chains/<name>/chain.json      entries, head, policy echo, codec name
/// chains/<name>/<n>.delta       zstd --patch-from frames (n = sequence)
/// ```
///
/// Laws: identical content is a no-op write (rebuilding stops being a
/// storage decision); every materialization step is hash-verified
/// (identity = digest); a missing or unrunnable codec degrades to
/// SnapshotOnly and says so in the receipt.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'codec.dart';
import 'rule.dart';

/// One recorded revision's receipt.
final class RecordReceipt {
  const RecordReceipt({
    required this.name,
    required this.sha256,
    required this.kind,
    this.unchanged = false,
    this.degradedTo,
    this.deltaSize,
    this.fullSize,
  });

  final String name;
  final String sha256;

  /// `snapshot | delta`.
  final String kind;

  /// Identical head content: nothing was written (dedup law).
  final bool unchanged;

  /// Why a DeltaChain policy stored a snapshot instead, when it did
  /// (`codec-unavailable`, `ratio`, `depth`, `cadence`, `first`).
  final String? degradedTo;

  final int? deltaSize;
  final int? fullSize;

  Map<String, Object?> toJson() => {
    'name': name,
    'sha256': sha256,
    'kind': kind,
    if (unchanged) 'unchanged': true,
    if (degradedTo != null) 'degradedTo': degradedTo,
    if (deltaSize != null) 'deltaSize': deltaSize,
    if (fullSize != null) 'fullSize': fullSize,
  };

  @override
  String toString() {
    final head = '$name ${kind.padRight(8)} ${sha256.substring(0, 12)}';
    if (unchanged) return '$head (unchanged)';
    if (deltaSize != null && fullSize != null) {
      return '$head (delta $deltaSize / full $fullSize)';
    }
    if (degradedTo != null) return '$head (snapshot; $degradedTo)';
    return head;
  }
}

/// Result of walking a chain back to full bytes.
final class Materialization {
  const Materialization({required this.bytes, required this.sha256});

  final Uint8List bytes;
  final String sha256;
}

final class VerifyReport {
  const VerifyReport({required this.ok, this.problems = const <String>[]});

  final bool ok;
  final List<String> problems;
}

/// One chain entry in the manifest.
final class _Entry {
  _Entry({
    required this.kind,
    required this.resultSha,
    this.blobSha,
    this.deltaSize,
  });

  factory _Entry.fromJson(Map<String, Object?> json) => _Entry(
    kind: json['kind']! as String,
    resultSha: json['resultSha']! as String,
    blobSha: json['blobSha'] as String?,
    deltaSize: json['deltaSize'] as int?,
  );

  /// `snapshot | delta`.
  final String kind;

  /// sha256 of the artifact after applying this entry.
  final String resultSha;

  /// Snapshot entry: the blob holding the full bytes.
  final String? blobSha;

  final int? deltaSize;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'resultSha': resultSha,
    if (blobSha != null) 'blobSha': blobSha,
    if (deltaSize != null) 'deltaSize': deltaSize,
  };
}

final class _Chain {
  _Chain({
    required this.name,
    required this.entries,
    required this.codec,
    required this.policy,
  });

  factory _Chain.fromJson(Map<String, Object?> json) => _Chain(
    name: json['name']! as String,
    codec: json['codec']! as String,
    policy: StorageStrategy.fromJson(json['policy']! as Map<String, Object?>),
    entries: [
      for (final entry
          in (json['entries']! as List<Object?>).cast<Map<String, Object?>>())
        _Entry.fromJson(entry),
    ],
  );

  final String name;
  final List<_Entry> entries;
  final String codec;
  final StorageStrategy policy;

  _Entry get head => entries.last;

  Map<String, Object?> toJson() => {
    'name': name,
    'codec': codec,
    'policy': policy.toJson(),
    'entries': [for (final entry in entries) entry.toJson()],
  };
}

/// The store. All writes are atomic (temp + rename); all reads verify
/// hashes at every step.
final class ArtifactStore {
  ArtifactStore({required this.root});

  /// The default machine store: `~/.oka/artifacts`.
  factory ArtifactStore.forMachine() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME is not set; cannot locate ~/.oka/artifacts');
    }
    return ArtifactStore(root: Directory(p.join(home, '.oka', 'artifacts')));
  }

  final Directory root;

  Directory get _blobs => Directory(p.join(root.path, 'blobs'));
  Directory _chainDir(String name) =>
      Directory(p.join(root.path, 'chains', _safe(name)));

  File _chainFile(String name) =>
      File(p.join(_chainDir(name).path, 'chain.json'));

  /// Artifact names are store keys, not paths: one segment, no tricks.
  String _safe(String name) {
    if (name.isEmpty ||
        name.length > 128 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(name)) {
      throw ArgumentError(
        'artifact name must match [A-Za-z0-9][A-Za-z0-9._-]* '
        '(got "$name")',
      );
    }
    return name;
  }

  String _shaOf(List<int> bytes) => sha256.convert(bytes).toString();

  /// Records one revision under [name] according to [policy]. Identical
  /// head content is a no-op ([RecordReceipt.unchanged]). A
  /// [DeltaChain] policy degrades to a snapshot — and says so — when
  /// the codec is unavailable, the ratio stops paying, the depth or
  /// cadence bound fires, or the chain is new.
  RecordReceipt record(
    List<int> bytes, {
    required String name,
    required StorageStrategy policy,
    required DeltaCodec codec,
    DateTime? now,
  }) {
    _safe(name);
    final sha = _shaOf(bytes);
    final chain = _readChain(name);
    if (chain != null && chain.head.resultSha == sha) {
      return RecordReceipt(
        name: name,
        sha256: sha,
        kind: 'snapshot',
        unchanged: true,
      );
    }

    switch (policy) {
      case SnapshotOnly():
        _writeSnapshot(name, bytes, sha, chain, policy, codec);
        return RecordReceipt(name: name, sha256: sha, kind: 'snapshot');
      case DeltaChain():
        final decision = _deltaOrSnapshot(
          bytes: bytes,
          sha: sha,
          chain: chain,
          policy: policy,
          codec: codec,
        );
        if (decision == null) {
          _writeSnapshot(name, bytes, sha, chain, policy, codec);
          return RecordReceipt(
            name: name,
            sha256: sha,
            kind: 'snapshot',
            degradedTo: chain == null
                ? 'first'
                : codec.isAvailable
                ? 'ratio-or-bound'
                : 'codec-unavailable',
            fullSize: bytes.length,
          );
        }
        final deltaBytes = decision;
        _appendDelta(name, bytes, sha, chain!, policy, codec, deltaBytes);
        return RecordReceipt(
          name: name,
          sha256: sha,
          kind: 'delta',
          deltaSize: deltaBytes.length,
          fullSize: bytes.length,
        );
    }
  }

  /// Returns the delta bytes to store, or null when this revision must
  /// be a snapshot.
  Uint8List? _deltaOrSnapshot({
    required List<int> bytes,
    required String sha,
    required _Chain? chain,
    required DeltaChain policy,
    required DeltaCodec codec,
  }) {
    if (chain == null) return null; // first revision is always a snapshot
    if (!codec.isAvailable) return null;
    final deltasSinceSnapshot = chain.entries.reversed
        .takeWhile((e) => e.kind == 'delta')
        .length;
    if (deltasSinceSnapshot >= policy.maxChainDepth) return null;
    if (deltasSinceSnapshot + 1 >= policy.orEvery) return null;

    final head = materialize(name: chain.name, codec: codec);
    final deltaBytes = codec.delta(base: head.bytes, target: bytes);
    final ratio = deltaBytes.length / bytes.length;
    if (ratio > policy.rolloverWhen.over) return null;
    return deltaBytes;
  }

  void _writeSnapshot(
    String name,
    List<int> bytes,
    String sha,
    _Chain? chain,
    StorageStrategy policy,
    DeltaCodec codec,
  ) {
    _blobs.createSync(recursive: true);
    final blob = File(p.join(_blobs.path, sha));
    if (!blob.existsSync()) {
      File('${blob.path}.tmp')
        ..writeAsBytesSync(bytes)
        ..renameSync(blob.path);
    }
    final entry = _Entry(kind: 'snapshot', resultSha: sha, blobSha: sha);
    // Retention amendment (ADR-0043, 2026-11-04): the store reads the
    // head only, so revisions before the newest snapshot are unreachable
    // cache bytes. Truncate the manifest to the fresh snapshot; their
    // frames and blobs become sweep garbage (this is the leak that buried
    // harnessd-jit-dill at 964 MB across 115 retained deltas). Frames are
    // deleted by [sweep] against CURRENT manifests, never inline, so a
    // concurrent reader holding the previous manifest stays consistent.
    _writeChain(
      _Chain(
        name: name,
        entries: [entry],
        codec: codec.name,
        policy: policy,
      ),
    );
  }

  void _appendDelta(
    String name,
    List<int> bytes,
    String sha,
    _Chain chain,
    DeltaChain policy,
    DeltaCodec codec,
    Uint8List deltaBytes,
  ) {
    final dir = _chainDir(name)..createSync(recursive: true);
    final n = chain.entries.length;
    final deltaFile = File(p.join(dir.path, '$n.delta'));
    File('${deltaFile.path}.tmp')
      ..writeAsBytesSync(deltaBytes)
      ..renameSync(deltaFile.path);
    final entry = _Entry(
      kind: 'delta',
      resultSha: sha,
      deltaSize: deltaBytes.length,
    );
    _writeChain(
      _Chain(
        name: name,
        entries: [...chain.entries, entry],
        codec: codec.name,
        policy: policy,
      ),
    );
  }

  /// Walks the chain back to the current full bytes, hash-verifying
  /// every step. Throws [StateError] when the chain does not exist.
  /// [codec] is required once the chain contains deltas; snapshot-only
  /// chains materialize without one.
  Materialization materialize({
    required String name,
    DeltaCodec? codec,
  }) {
    final chain = _readChain(name);
    if (chain == null) {
      throw StateError('no artifact chain for "$name"');
    }
    final hasDeltas = chain.entries.any((e) => e.kind == 'delta');
    if (hasDeltas && (codec == null || !codec.isAvailable)) {
      throw ArtifactStoreCorruptException(name, [
        if (codec == null)
          'chain has deltas but no codec was provided'
        else
          'codec unavailable: ${codec.unavailability}',
      ]);
    }
    final problems = <String>[];
    // Walk from the LAST snapshot, not from history's start: the store
    // reads the head only (ADR-0043 retention amendment, 2026-11-04), so
    // entries before the newest snapshot are unreachable by design and
    // must not make materialization cost grow with chain age.
    var start = 0;
    for (var i = chain.entries.length - 1; i >= 0; i--) {
      if (chain.entries[i].kind == 'snapshot') {
        start = i;
        break;
      }
    }
    Uint8List? bytes;
    for (var index = start; index < chain.entries.length; index++) {
      final entry = chain.entries[index];
      switch (entry.kind) {
        case 'snapshot':
          final blobSha = entry.blobSha;
          if (blobSha == null) {
            problems.add('snapshot entry at ${entry.resultSha} has no blob');
            continue;
          }
          final blob = File(p.join(_blobs.path, blobSha));
          if (!blob.existsSync()) {
            problems.add('missing snapshot blob $blobSha');
            continue;
          }
          bytes = Uint8List.fromList(blob.readAsBytesSync());
        case 'delta':
          if (bytes == null) {
            problems.add('delta at ${entry.resultSha} has no base');
            continue;
          }
          final deltaFile = File(p.join(_chainDir(name).path, '$index.delta'));
          if (!deltaFile.existsSync()) {
            problems.add('missing delta frame for ${entry.resultSha}');
            continue;
          }
          bytes = codec!.undelta(
            base: bytes,
            deltaBytes: Uint8List.fromList(deltaFile.readAsBytesSync()),
          );
      }
      final actual = _shaOf(bytes!);
      if (actual != entry.resultSha) {
        problems.add(
          'hash mismatch after ${entry.kind}: $actual != ${entry.resultSha}',
        );
        // A mismatch poisons every later delta; stop here and report.
        break;
      }
    }
    if (problems.isNotEmpty) {
      throw ArtifactStoreCorruptException(name, problems);
    }
    if (bytes == null) {
      throw ArtifactStoreCorruptException(name, ['chain has no entries']);
    }
    return Materialization(bytes: bytes, sha256: _shaOf(bytes));
  }

  /// Re-materializes the chain purely to check integrity.
  VerifyReport verify({required String name, DeltaCodec? codec}) {
    try {
      materialize(name: name, codec: codec);
      return const VerifyReport(ok: true);
    } on ArtifactStoreCorruptException catch (error) {
      return VerifyReport(ok: false, problems: error.problems);
    }
  }

  /// Human-oriented chain summary for `status`.
  Map<String, Object?>? status({required String name}) {
    final chain = _readChain(name);
    if (chain == null) return null;
    final snapshots = chain.entries
        .where((e) => e.kind == 'snapshot')
        .length;
    final deltas = chain.entries.length - snapshots;
    return {
      'name': name,
      'head': chain.head.resultSha,
      'revisions': chain.entries.length,
      'snapshots': snapshots,
      'deltas': deltas,
      'codec': chain.codec,
      'policy': chain.policy.toJson(),
    };
  }

  /// Every chain name in the store, sorted.
  List<String> names() {
    final dir = Directory(p.join(root.path, 'chains'));
    if (!dir.existsSync()) return const <String>[];
    return dir
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toList()
      ..sort();
  }

  /// Store garbage collection (ADR-0043 retention amendment, 2026-11-04).
  ///
  /// Best-effort and never fatal; manifests are the only truth. Removes:
  /// - chains whose `chain.json` was last written before [chainTtl] ago
  ///   (renamed-runner orphans — the harnessd-jit-dill case);
  /// - blobs no surviving manifest references and delta frames the
  ///   chain's CURRENT manifest no longer references (compaction
  ///   leftovers). Fresher than [grace] is never touched — a concurrent
  ///   record may be mid-write.
  ///
  /// [dryRun] (the default) reports without deleting.
  Future<SweepReport> sweep({
    Duration chainTtl = const Duration(days: 30),
    Duration grace = const Duration(hours: 1),
    bool dryRun = true,
  }) async {
    final report = SweepReport();
    final now = DateTime.now();
    final chainsRoot = Directory(p.join(root.path, 'chains'));
    final referencedBlobs = <String>{};
    final referencedFrames = <String>{};

    final chainDirs = chainsRoot.existsSync()
        ? chainsRoot.listSync().whereType<Directory>().toList()
        : const <Directory>[];
    for (final dir in chainDirs) {
      final manifest = File(p.join(dir.path, 'chain.json'));
      if (!manifest.existsSync()) {
        report.brokenChains.add(dir.path);
        continue;
      }
      if (now.difference(manifest.statSync().modified) > chainTtl) {
        report.chainDirs.add(dir.path);
        continue;
      }
      try {
        final chain = _Chain.fromJson(
          jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>,
        );
        for (var i = 0; i < chain.entries.length; i++) {
          final entry = chain.entries[i];
          if (entry.blobSha != null) referencedBlobs.add(entry.blobSha!);
          if (entry.kind == 'delta') {
            referencedFrames.add(p.join(dir.path, '$i.delta'));
          }
        }
      } on FormatException {
        report.brokenChains.add(dir.path);
      }
    }

    for (final dir in chainDirs) {
      if (report.chainDirs.contains(dir.path) ||
          report.brokenChains.contains(dir.path)) {
        continue;
      }
      for (final f in dir.listSync().whereType<File>()) {
        if (p.extension(f.path) != '.delta') continue;
        if (referencedFrames.contains(f.path)) continue;
        if (now.difference(f.statSync().modified) <= grace) continue;
        report.deltaFiles.add(f.path);
        report.bytes += f.lengthSync();
      }
    }
    final blobs = Directory(p.join(root.path, 'blobs'));
    if (blobs.existsSync()) {
      for (final f in blobs.listSync().whereType<File>()) {
        if (referencedBlobs.contains(p.basename(f.path))) continue;
        if (now.difference(f.statSync().modified) <= grace) continue;
        report.blobs.add(f.path);
        report.bytes += f.lengthSync();
      }
    }

    if (dryRun) return report;
    for (final path in report.chainDirs) {
      try {
        Directory(path).deleteSync(recursive: true);
      } on FileSystemException {
        report.failures.add(path);
      }
    }
    for (final path in [...report.deltaFiles, ...report.blobs]) {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        report.failures.add(path);
      }
    }
    return report;
  }

  _Chain? _readChain(String name) {
    final file = _chainFile(name);
    if (!file.existsSync()) return null;
    return _Chain.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    );
  }

  void _writeChain(_Chain chain) {
    final chainFile = _chainFile(chain.name);
    chainFile.parent.createSync(recursive: true);
    File('${chainFile.path}.tmp')
      ..writeAsStringSync('${encodeCanonical(chain.toJson())}\n')
      ..renameSync(chainFile.path);
  }
}

/// What [ArtifactStore.sweep] found (and, when applying, deleted).
final class SweepReport {
  final chainDirs = <String>[];
  final brokenChains = <String>[];
  final deltaFiles = <String>[];
  final blobs = <String>[];
  final failures = <String>[];

  /// Reclaimable bytes across [deltaFiles] and [blobs].
  int bytes = 0;

  Map<String, Object?> toJson() => {
    'chainDirs': chainDirs.length,
    'brokenChains': brokenChains.length,
    'deltaFiles': deltaFiles.length,
    'blobs': blobs.length,
    'failures': failures.length,
    'bytes': bytes,
  };
}

/// A chain failed integrity during materialization; the problems name
/// each broken link. Never silently truncated.
final class ArtifactStoreCorruptException implements Exception {
  ArtifactStoreCorruptException(this.name, this.problems);

  final String name;
  final List<String> problems;

  @override
  String toString() =>
      'artifact chain "$name" is corrupt:\n'
      '${problems.map((p) => '  - $p').join('\n')}';
}
