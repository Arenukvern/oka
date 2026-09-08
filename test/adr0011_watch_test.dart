// ADR-0011 H4 — `--watch` change classification (table-driven over
// file-event fixtures), debounce, computeDevWatchPaths over fixture trees,
// and classification → session-command routing.
import 'dart:async';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('classifyChanges (table-driven over file-event fixtures)', () {
    ChangeAction actionOf(final Iterable<String> paths) =>
        classifyChanges(paths).action;

    test('Dart-only under lib/ routes to hot reload', () {
      expect(actionOf(['lib/main.dart']), ChangeAction.hotReload);
      expect(
        actionOf(['lib/src/pipeline/toolchain.dart']),
        ChangeAction.hotReload,
      );
      expect(
        actionOf(['lib/main.dart', 'lib/foo.dart']),
        ChangeAction.hotReload,
      );
      final c = classifyChanges(['lib/main.dart']);
      expect(c.reasons.single, contains('Dart (reload)'));
    });

    test('non-Dart under lib/ is a bundled asset → full rebuild', () {
      expect(actionOf(['lib/assets/config.json']), ChangeAction.fullRebuild);
      expect(actionOf(['lib/main.g.dart']), ChangeAction.hotReload);
      expect(actionOf(['lib/icon.png']), ChangeAction.fullRebuild);
    });

    test('tests/tooling never affect the running app', () {
      expect(actionOf(['test/foo_test.dart']), ChangeAction.ignore);
      expect(actionOf(['tool/oka_pipeline.dart']), ChangeAction.ignore);
      expect(actionOf(['bin/oka_pipeline.dart']), ChangeAction.ignore);
      final c = classifyChanges(['test/foo_test.dart']);
      expect(c.reasons.single, contains('ignored'));
    });

    test('native/res/manifest surface routes to full rebuild', () {
      const native = [
        'android/app/src/main/AndroidManifest.xml',
        'android/build.gradle',
        'android/app/src/main/kotlin/dev/example/MainActivity.kt',
        'android/app/src/main/java/dev/example/MainActivity.java',
        'android/app/src/main/res/mipmap/icon.png',
        'native.so',
        'libs/testnative.aar',
        'proguard-rules.pro',
      ];
      for (final path in native) {
        expect(
          actionOf([path]),
          ChangeAction.fullRebuild,
          reason: '$path must route to a full rebuild',
        );
        expect(
          classifyChanges([path]).reasons.single,
          contains('full rebuild'),
        );
      }
    });

    test('assets surface routes to full rebuild', () {
      expect(actionOf(['assets/hello.txt']), ChangeAction.fullRebuild);
    });

    test('config/dependency files route to full rebuild', () {
      expect(actionOf(['oka.yaml']), ChangeAction.fullRebuild);
      expect(actionOf(['pubspec.yaml']), ChangeAction.fullRebuild);
      expect(actionOf(['pubspec.lock']), ChangeAction.fullRebuild);
    });

    test('build/meta paths are ignored', () {
      const meta = [
        '.oka_cache/build/debug/app-debug.apk',
        '.dart_tool/package_config.json',
        'build/generated.txt',
        '.git/HEAD',
        '.gitignore',
      ];
      for (final path in meta) {
        expect(actionOf([path]), ChangeAction.ignore, reason: path);
      }
    });

    test('absolute Windows-style and absolute paths normalize', () {
      expect(actionOf([r'C:\proj\lib\main.dart']), ChangeAction.hotReload);
    });

    test('strongest action wins in mixed batches', () {
      expect(
        actionOf(['lib/main.dart', 'android/AndroidManifest.xml']),
        ChangeAction.fullRebuild,
        reason: 'any rebuild-class path routes the whole batch',
      );
      final c = classifyChanges(['lib/main.dart', 'assets/hello.txt']);
      expect(c.action, ChangeAction.fullRebuild);
      expect(c.reasons, hasLength(2));
      expect(c.reasons.first, contains('lib/main.dart'));
    });

    test('hot reload never regresses via a later ignore-class path', () {
      expect(
        actionOf(['lib/main.dart', '.dart_tool/x.json']),
        ChangeAction.hotReload,
      );
    });
  });

  group('debounceStream', () {
    test('a save storm dispatches exactly one batch', () async {
      final src = StreamController<String>();
      final debounced = debounceStream(
        src.stream,
        const Duration(milliseconds: 40),
      );
      final batches = <List<String>>[];
      final sub = debounced.listen(batches.add);
      for (var i = 0; i < 5; i++) {
        src.add('lib/file$i.dart');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(batches, hasLength(1));
      expect(batches.single, hasLength(5));
      await sub.cancel();
      await src.close();
    });

    test('separated events dispatch separately; trailing batch flushes '
        'on done', () async {
      final src = StreamController<String>();
      final debounced = debounceStream(
        src.stream,
        const Duration(milliseconds: 20),
      );
      final batches = <List<String>>[];
      final sub = debounced.listen(batches.add);
      src.add('lib/a.dart');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      src.add('lib/b.dart');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await src.close();
      await Future<void>.delayed(Duration.zero);
      expect(batches, [
        ['lib/a.dart'],
        ['lib/b.dart'],
      ]);
      await sub.cancel();
    });
  });

  group('watchCommandStream (classification → routing)', () {
    test('dart batch → reload; native batch → rebuildRouting; ignore → '
        'nothing', () async {
      final src = StreamController<List<String>>();
      final events = <ChangeClassification>[];
      final commands = <DevControlCommand>[];
      final sub = watchCommandStream(
        changes: src.stream,
        onEvent: events.add,
      ).listen(commands.add);
      addTearDown(sub.cancel);
      src.add(['lib/main.dart']);
      src.add(['android/AndroidManifest.xml']);
      src.add(['.dart_tool/x.json']);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await src.close();
      expect(events, hasLength(3));
      expect(commands, [
        DevControlCommand.reload,
        DevControlCommand.rebuildRouting,
      ]);
    });
  });

  group('computeDevWatchPaths (fixture tree)', () {
    late Directory project;
    setUp(() {
      project = Directory.systemTemp.createTempSync('oka_watch_tree');
      Directory(p.join(project.path, 'lib')).createSync();
      Directory(p.join(project.path, 'android')).createSync();
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('name: x');
      File(p.join(project.path, 'lib', 'main.dart')).writeAsStringSync('v(){}');
    });
    tearDown(() => project.deleteSync(recursive: true));

    test('watches lib/, android/, pubspec.yaml; missing assets skipped', () {
      final paths = computeDevWatchPaths(projectPath: project.path);
      final names = paths.map(p.basename).toSet();
      expect(names, containsAll(['lib', 'android', 'pubspec.yaml']));
      expect(names, isNot(contains('assets')));
      expect(paths.every(p.isAbsolute), isTrue);
    });

    test('target file inside lib/ is covered by the lib/ root (no '
        'double-watch)', () {
      final paths = computeDevWatchPaths(
        projectPath: project.path,
        targetFile: 'lib/main.dart',
      );
      expect(
        paths.where((final w) => p.basename(w) == 'main.dart'),
        isEmpty,
        reason: 'the lib/ root already watches it — no file root added',
      );
    });

    test('external target file is watched', () {
      final external = File(p.join(project.parent.path, 'alt_main.dart'))
        ..writeAsStringSync('v(){}');
      addTearDown(external.deleteSync);
      final paths = computeDevWatchPaths(
        projectPath: project.path,
        targetFile: external.path,
      );
      expect(paths, contains(external.path));
    });
  });

  group('watchDevPaths (real watcher smoke test)', () {
    late Directory project;
    setUp(() {
      project = Directory.systemTemp.createTempSync('oka_watch_smoke');
      Directory(p.join(project.path, 'lib')).createSync();
    });
    tearDown(() => project.deleteSync(recursive: true));

    test('editing a Dart file yields a relative hot-reload batch', () async {
      final main = File(p.join(project.path, 'lib', 'main.dart'))
        ..writeAsStringSync('v(){}');
      final changes = watchDevPaths(
        projectPath: project.path,
        debounce: const Duration(milliseconds: 30),
      );
      final batches = <List<String>>[];
      final sub = changes.listen(batches.add);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await main.writeAsString('v2(){}');
      // macOS FSEvents latency can exceed a second; poll until observed.
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (batches.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await sub.cancel();
      expect(batches, isNotEmpty);
      final allPaths = batches.expand((final b) => b).toSet();
      final classification = classifyChanges(allPaths);
      expect(classification.action, ChangeAction.hotReload);
      expect(classification.reasons.join('; '), contains('lib/main.dart'));
    });
  });
}
