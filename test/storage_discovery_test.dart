import 'dart:io';

import 'package:oka/src/cli/storage_discovery.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String home;
  late String project;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('oka-discovery-');
    home = p.join(root.path, 'home');
    project = p.join(root.path, 'project');
    await Directory(home).create();
    await Directory(project).create();
  });
  tearDown(() => root.delete(recursive: true));
  Future<void> file(String path) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString('data');
  }

  test(
    'build units preserve nested browser profiles and unknown state',
    () async {
      await file(p.join(project, '.oka_cache/build/debug/app.apk'));
      await file(
        p.join(project, '.oka_cache/build/web/chrome-profiles/work/data'),
      );
      await file(p.join(project, '.oka_cache/build/web/output/index.html'));
      await file(p.join(project, '.oka_cache/custom/data'));
      final locations = await discoverStorageLocations(
        projectPath: project,
        environment: {'HOME': home},
        hostPlatform: 'linux',
      );
      expect(
        locations.where((l) => l.prunable).map((l) => p.basename(l.path)),
        containsAll(['debug', 'output']),
      );
      expect(
        locations.singleWhere((l) => l.category == 'browser-profiles').prunable,
        isFalse,
      );
      expect(
        locations.singleWhere((l) => p.basename(l.path) == 'custom').prunable,
        isFalse,
      );
      expect(locations.any((l) => p.basename(l.path) == 'web'), isFalse);
    },
  );
  test('corrupt process lease conservatively protects builds', () async {
    await file(p.join(project, '.oka_cache/build/release/app.apk'));
    await file(p.join(project, '.oka_cache/processes/corrupt.json'));
    final locations = await discoverStorageLocations(
      projectPath: project,
      environment: {'HOME': home},
      hostPlatform: 'linux',
    );
    final build = locations.singleWhere((l) => l.category == 'build-output');
    expect(build.prunable, isFalse);
    expect(build.note, contains('Unreadable process leases'));
  });
  test(
    'discovers SDK components, configured AVD and external caches',
    () async {
      final avds = p.join(root.path, 'avds');
      final device = p.join(root.path, 'custom-device');
      await file(p.join(home, '.oka/android-sdk/system-images/api/image'));
      await file(p.join(home, '.oka/android-sdk/emulator/emulator'));
      await file(p.join(home, '.oka/store/future-platform/artifact'));
      await file(p.join(home, '.pub-cache/package/file'));
      await file(p.join(device, 'userdata.img'));
      await file(p.join(avds, 'pixel.ini'));
      await File(p.join(avds, 'pixel.ini')).writeAsString('path=$device\n');
      final locations = await discoverStorageLocations(
        projectPath: project,
        environment: {'HOME': home, 'ANDROID_AVD_HOME': avds},
        hostPlatform: 'linux',
      );
      expect(locations.singleWhere((l) => l.path == device).prunable, isFalse);
      expect(
        locations.where((l) => l.category.startsWith('android-sdk')).length,
        2,
      );
      expect(
        locations
            .where((l) => l.category.startsWith('android-sdk'))
            .every((l) => !l.prunable),
        isTrue,
      );
      expect(
        locations
            .singleWhere((l) => l.category == 'shared-future-platform')
            .scope,
        'shared',
      );
      expect(
        locations.singleWhere((l) => l.category == 'dart-pub-cache').prunable,
        isFalse,
      );
    },
  );
  test(
    'discovers Apple simulator data and Flutter cache as informational',
    () async {
      final flutter = p.join(root.path, 'flutter');
      await file(
        p.join(home, 'Library/Developer/CoreSimulator/Devices/id/data'),
      );
      await file(p.join(flutter, 'bin/cache/web-sdk/file'));
      final locations = await discoverStorageLocations(
        projectPath: project,
        environment: {'HOME': home, 'FLUTTER_ROOT': flutter},
        hostPlatform: 'macos',
      );
      expect(
        locations
            .singleWhere((l) => l.category == 'apple-simulator-devices')
            .prunable,
        isFalse,
      );
      expect(
        locations
            .singleWhere((l) => l.category == 'flutter-sdk-cache')
            .prunable,
        isFalse,
      );
    },
  );
  test('SDK protection wins when OKA_CACHE points at SDK root', () async {
    final sdk = p.join(home, '.oka', 'android-sdk');
    await file(p.join(sdk, 'system-images', 'api', 'image'));
    final locations = await discoverStorageLocations(
      projectPath: project,
      environment: {'HOME': home, 'OKA_CACHE': sdk},
      hostPlatform: 'linux',
    );
    final image = locations.singleWhere(
      (l) => l.category == 'android-sdk-system-images',
    );
    expect(image.prunable, isFalse);
    expect(image.category, 'android-sdk-system-images');
  });
  test(
    'cache overrides cannot prune the project registry or its lock',
    () async {
      final canonicalHome = await Directory(home).resolveSymbolicLinks();
      final oka = p.join(canonicalHome, '.oka');
      final registry = p.join(oka, 'cache-projects.json');
      await file(registry);
      await file('$registry.lock');
      await file(p.join(oka, 'store', 'artifact'));
      final locations = await discoverStorageLocations(
        projectPath: project,
        environment: {'HOME': canonicalHome, 'OKA_CACHE': oka},
        hostPlatform: 'linux',
      );
      expect(
        locations.where((l) => l.category == 'project-registry'),
        hasLength(2),
      );
      final result = await StorageInventory(
        locations: locations,
      ).prune(apply: true);
      expect(result.errors, isEmpty);
      expect(await File(registry).readAsString(), 'data');
      expect(await File('$registry.lock').readAsString(), 'data');
      expect(await File(p.join(oka, 'store', 'artifact')).exists(), isFalse);
    },
  );
  test('reports individual Android images and Apple devices', () async {
    final images = p.join(home, '.oka/android-sdk/system-images');
    await file(p.join(images, 'android-35/google_apis/arm64-v8a/system.img'));
    await file(p.join(images, 'android-36/google_apis/x86_64/system.img'));
    final devices = p.join(home, 'Library/Developer/CoreSimulator/Devices');
    await file(p.join(devices, 'first-udid/data/file'));
    await file(p.join(devices, 'second-udid/data/file'));
    final locations = await discoverStorageLocations(
      projectPath: project,
      environment: {'HOME': home},
      hostPlatform: 'macos',
    );
    final imageLocations = locations.where(
      (l) => l.category == 'android-sdk-system-images',
    );
    expect(
      imageLocations.map((l) => p.basename(l.path)),
      containsAll(['arm64-v8a', 'x86_64']),
    );
    expect(imageLocations.length, 2);
    expect(imageLocations.every((l) => !l.prunable), isTrue);
    final deviceLocations = locations.where(
      (l) => l.category == 'apple-simulator-devices',
    );
    expect(
      deviceLocations.map((l) => p.basename(l.path)),
      containsAll(['first-udid', 'second-udid']),
    );
    expect(deviceLocations.length, 2);
  });
  test('symlink build roots are protected', () async {
    final target = p.join(root.path, 'outside');
    await file(p.join(target, 'user-data'));
    await Link(p.join(project, '.oka_cache')).create(target);
    final locations = await discoverStorageLocations(
      projectPath: project,
      environment: {'HOME': home},
      hostPlatform: 'linux',
    );
    expect(locations.single.prunable, isFalse);
    expect(locations.single.note, contains('Symbolic link'));
  }, skip: Platform.isWindows ? 'Symlink privileges vary on Windows.' : false);
}
