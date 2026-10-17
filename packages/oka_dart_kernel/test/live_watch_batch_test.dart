import 'dart:async';

import 'package:test/test.dart';

import '../tool/live_watch_batch.dart';

void main() {
  test(
    'multi-file burst retains distinct units and deduplicates repeat saves',
    () async {
      final applied = <String>[];
      final batch = LiveWatchBatch(
        apply: (path) async {
          applied.add(path);
        },
        onError: (_, error, _) => fail('$error'),
      );
      batch.schedule('actor_view_projection.dart');
      batch.schedule('project_execution_context.dart');
      batch.schedule('actor_view_projection.dart');
      batch.schedule('project_scope.dart');
      await batch.close();
      expect(applied, [
        'actor_view_projection.dart',
        'project_execution_context.dart',
        'project_scope.dart',
      ]);
    },
  );

  test('debounce timer drains the complete burst', () async {
    final applied = <String>[];
    final settled = Completer<void>();
    final batch = LiveWatchBatch(
      debounce: const Duration(milliseconds: 1),
      apply: (path) async {
        applied.add(path);
        if (applied.length == 2) settled.complete();
      },
      onError: (_, error, _) => fail('$error'),
    );
    try {
      batch.schedule('first.dart');
      batch.schedule('second.dart');
      await settled.future.timeout(const Duration(seconds: 2));
      expect(applied, ['first.dart', 'second.dart']);
    } finally {
      await batch.close();
    }
  });

  test('saves during blocked apply are queued and never overlap', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final applied = <String>[];
    var active = 0;
    var maxActive = 0;
    final batch = LiveWatchBatch(
      apply: (path) async {
        active++;
        if (active > maxActive) maxActive = active;
        applied.add(path);
        if (path == 'first.dart') {
          entered.complete();
          await release.future;
        }
        active--;
      },
      onError: (_, error, _) => fail('$error'),
    );
    batch.schedule('first.dart');
    batch.flush();
    await entered.future;
    batch.schedule('second.dart');
    batch.schedule('third.dart');
    batch.schedule('second.dart');
    batch.flush();
    await Future<void>.delayed(Duration.zero);
    expect(applied, ['first.dart']);
    release.complete();
    await batch.close();
    expect(applied, ['first.dart', 'second.dart', 'third.dart']);
    expect(maxActive, 1);
  });

  test(
    'failed compile does not discard remaining units or poison next batch',
    () async {
      final applied = <String>[];
      final failed = <String>[];
      final batch = LiveWatchBatch(
        apply: (path) async {
          applied.add(path);
          if (path == 'broken.dart') {
            throw StateError('controlled compile failure');
          }
        },
        onError: (path, _, _) {
          failed.add(path);
        },
      );
      batch.schedule('broken.dart');
      batch.schedule('valid.dart');
      batch.flush();
      batch.schedule('later.dart');
      await batch.close();
      expect(applied, ['broken.dart', 'valid.dart', 'later.dart']);
      expect(failed, ['broken.dart']);
      expect(() => batch.schedule('closed.dart'), throwsStateError);
    },
  );
}
