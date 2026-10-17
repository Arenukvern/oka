import 'dart:async';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

void main() {
  test('stop cancels each directory source, not only the last one', () async {
    var cancellations = 0;
    final watched = <String>[];
    final controllers = <StreamController<FileSystemEvent>>[];
    final watcher = LiveWatcher(
      unit: 'test',
      files: ['/app/lib/a.dart', '/external/lib/b.dart'],
      revision: 'test',
      targets: const [],
      probes: const [],
      root: '/app',
      compile: (_) async =>
          throw StateError('No edits in this lifecycle trial'),
      watchDirectory: (directory) {
        watched.add(directory.path);
        final controller = StreamController<FileSystemEvent>(
          onCancel: () => cancellations++,
        );
        controllers.add(controller);
        return controller.stream;
      },
    );
    watcher.start();
    expect(watched, hasLength(2));
    await watcher.stop();
    expect(cancellations, 2);
    for (final controller in controllers) {
      await controller.close();
    }
  });
}
