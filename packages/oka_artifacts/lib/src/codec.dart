/// The delta codec seam (ADR-0043 decision 4): the store is
/// format-agnostic; a codec turns (base, target) into delta bytes and
/// back. Absent codecs degrade loudly to SnapshotOnly in the receipt —
/// never a silent policy change.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Encodes target against base and reconstructs target from (base, delta).
abstract interface class DeltaCodec {
  /// Stable codec name recorded in the chain manifest.
  String get name;

  /// Whether the codec can run on this machine right now.
  bool get isAvailable;

  /// Named availability problem, for receipts when [isAvailable] is false.
  String? get unavailability;

  Uint8List delta({
    required final List<int> base,
    required final List<int> target,
  });

  Uint8List undelta({
    required final List<int> base,
    required final Uint8List deltaBytes,
  });
}

/// zstd `--patch-from` via the CLI (ADR-0043 decision 4: chosen codec —
/// fast, ubiquitous, one flag). Compression and decompression both need
/// the base file, which is exactly the chain materialization pattern.
final class ZstdCliCodec implements DeltaCodec {
  const ZstdCliCodec();

  static const String binary = 'zstd';

  @override
  String get name => 'zstd-cli';

  static bool? _available;
  static String? _unavailability;

  @override
  bool get isAvailable {
    _probe();
    return _available!;
  }

  @override
  String? get unavailability {
    _probe();
    return _unavailability;
  }

  void _probe() {
    if (_available != null) return;
    try {
      final result = Process.runSync(binary, const ['--version']);
      _available = result.exitCode == 0;
      _unavailability = _available!
          ? null
          : 'zstd exited ${result.exitCode}: ${result.stderr}';
    } on Object catch (error) {
      _available = false;
      _unavailability =
          '$binary not runnable: $error; '
          'install zstd or use SnapshotOnly';
    }
  }

  @override
  Uint8List delta({
    required final List<int> base,
    required final List<int> target,
  }) => _run(base: base, input: target, decompress: false);

  @override
  Uint8List undelta({
    required final List<int> base,
    required final Uint8List deltaBytes,
  }) => _run(base: base, input: deltaBytes, decompress: true);

  Uint8List _run({
    required final List<int> base,
    required final List<int> input,
    required final bool decompress,
  }) {
    final temp = Directory.systemTemp.createTempSync('oka_artifacts_zstd_');
    try {
      final basePath = _tempPath(temp, 'base');
      final inputPath = _tempPath(temp, decompress ? 'delta.zst' : 'target');
      final outputPath = _tempPath(temp, decompress ? 'target' : 'delta.zst');
      File(basePath).writeAsBytesSync(base);
      File(inputPath).writeAsBytesSync(input);
      final args = [
        '-q',
        if (decompress) '-d',
        '--patch-from=$basePath',
        '-o',
        outputPath,
        inputPath,
      ];
      final result = Process.runSync(binary, args);
      if (result.exitCode != 0) {
        throw ArtifactCodecException(
          'zstd --patch-from failed (${result.exitCode}): ${result.stderr}',
        );
      }
      return Uint8List.fromList(File(outputPath).readAsBytesSync());
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  static String _tempPath(final Directory dir, final String name) =>
      '${dir.path}/$name';
}

/// A codec operation failed mid-store.
final class ArtifactCodecException implements Exception {
  const ArtifactCodecException(this.message);

  final String message;

  @override
  String toString() => 'artifact codec failed: $message';
}

/// Deterministic invertible codec for tests: delta = length-prefixed
/// XOR of target against the repeated base. Delta size tracks target
/// size (ratio ~1.0 — chains never roll by ratio), so ratio-driven
/// rollover needs a controllable codec like [SharedPrefixCodec].
final class XorTestCodec implements DeltaCodec {
  const XorTestCodec();

  @override
  String get name => 'xor-test';

  @override
  bool get isAvailable => true;

  @override
  String? get unavailability => null;

  @override
  Uint8List delta({
    required final List<int> base,
    required final List<int> target,
  }) {
    final out = BytesBuilder();
    final length = ByteData(4)..setUint32(0, target.length);
    out.add(length.buffer.asUint8List());
    for (var i = 0; i < target.length; i++) {
      out.addByte(target[i] ^ base[i % base.length]);
    }
    return out.toBytes();
  }

  @override
  Uint8List undelta({
    required final List<int> base,
    required final Uint8List deltaBytes,
  }) {
    final length = ByteData.view(deltaBytes.buffer).getUint32(0);
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = deltaBytes[4 + i] ^ base[i % base.length];
    }
    return out;
  }
}

/// Test codec whose delta size tracks the *shared prefix*: tiny deltas
/// for tiny edits, huge deltas for unrelated content — ratio-driven
/// rollover becomes deterministically testable.
final class SharedPrefixCodec implements DeltaCodec {
  const SharedPrefixCodec();

  @override
  String get name => 'shared-prefix';

  @override
  bool get isAvailable => true;

  @override
  String? get unavailability => null;

  @override
  Uint8List delta({
    required final List<int> base,
    required final List<int> target,
  }) {
    var shared = 0;
    final limit = base.length < target.length ? base.length : target.length;
    while (shared < limit && base[shared] == target[shared]) {
      shared++;
    }
    final out = BytesBuilder();
    final length = ByteData(8)
      ..setUint32(0, shared)
      ..setUint32(4, target.length);
    out
      ..add(length.buffer.asUint8List())
      ..add(target.sublist(shared));
    return out.toBytes();
  }

  @override
  Uint8List undelta({
    required final List<int> base,
    required final Uint8List deltaBytes,
  }) {
    final header = ByteData.view(deltaBytes.buffer);
    final shared = header.getUint32(0);
    final length = header.getUint32(4);
    final out = Uint8List(length);
    for (var i = 0; i < shared; i++) {
      out[i] = base[i];
    }
    for (var i = shared; i < length; i++) {
      out[i] = deltaBytes[8 + i - shared];
    }
    return out;
  }
}

/// JSON helper shared by the store files (sorted keys, compact).
String encodeCanonical(final Map<String, Object?> value) =>
    const JsonEncoder.withIndent('  ').convert(value);
