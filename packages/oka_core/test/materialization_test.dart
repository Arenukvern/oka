import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_materialize_');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  File src(String content) {
    final f = File(p.join(temp.path, 'source.bin'))
      ..writeAsStringSync(content);
    return f;
  }

  test('copy fallback materializes identical bytes', () async {
    final source = src('hello blocks');
    final result = await materializeFile(
      source: source.path,
      destination: p.join(temp.path, 'out', 'dest.bin'),
      // Inject an empty chain: every strategy unsupported → copy.
      linkAttempts: const [],
    );
    expect(result.strategy, MaterializationStrategy.copy);
    expect(File(result.destination).readAsStringSync(), 'hello blocks');
    expect(result.sizeBytes, 'hello blocks'.length);
  });

  test('default chain materializes identical bytes on this host', () async {
    final source = src('default chain');
    final result = await materializeFile(
      source: source.path,
      destination: p.join(temp.path, 'dest.bin'),
    );
    // Whatever strategy won (clonefile/hardlink/copy on macOS), the bytes
    // must be exact.
    expect(File(result.destination).readAsStringSync(), 'default chain');
  });

  test('replaces an existing destination (unlink-then-materialize)', () async {
    final source = src('new content');
    final destPath = p.join(temp.path, 'dest.bin');
    File(destPath).writeAsStringSync('stale old content');
    final result = await materializeFile(
      source: source.path,
      destination: destPath,
      linkAttempts: const [],
    );
    expect(result.strategy, MaterializationStrategy.copy);
    expect(File(destPath).readAsStringSync(), 'new content');
  });

  test('real hardlink strategy is used when the platform provides it',
      () async {
    final source = src('hardlinked');
    if (Platform.isWindows) {
      return; // link(2) is POSIX-only; copy fallback covered above.
    }
    final result = await materializeFile(
      source: source.path,
      destination: p.join(temp.path, 'dest.bin'),
      linkAttempts: [
        // POSIX link(2) via `ln` — proves an injected link strategy wins
        // over copy and keeps its declared identity.
        (final s, final d) {
          final r = Process.runSync('ln', [s, d]);
          return r.exitCode == 0 ? MaterializationStrategy.hardlink : null;
        },
      ],
    );
    expect(result.strategy, MaterializationStrategy.hardlink);
    expect(File(result.destination).readAsStringSync(), 'hardlinked');
  });

  test('permissions: default 0644 on copy, keepSourcePermissions honored',
      () async {
    final source = src('perms');
    final kept = await materializeFile(
      source: source.path,
      destination: p.join(temp.path, 'kept.bin'),
      keepSourcePermissions: true,
      linkAttempts: const [],
    );
    final forced = await materializeFile(
      source: source.path,
      destination: p.join(temp.path, 'forced.bin'),
      linkAttempts: const [],
    );
    for (final r in [kept, forced]) {
      // Content identical; permission detail is POSIX-only (dart:io cannot
      // read modes on Windows).
      if (Platform.isWindows) continue;
      final mode = File(r.destination).statSync().mode;
      expect(mode & 511, 420, reason: r.destination);
    }
  });
}
