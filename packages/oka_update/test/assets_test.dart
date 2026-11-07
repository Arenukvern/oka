import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('oka-assets-test-');
    root = '${tmp.path}/app';
    Directory('$root/assets/icons').createSync(recursive: true);
    File('$root/pubspec.yaml').writeAsStringSync('''
name: app
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
  assets:
    - assets/hello.txt
    - assets/icons/
    # - assets/commented.png
''');
    File('$root/assets/hello.txt').writeAsStringSync('hello');
    File('$root/assets/icons/a.png').writeAsBytesSync([1]);
    File('$root/assets/icons/b.png').writeAsBytesSync([2]);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('declaredAssetFiles expands dirs, keeps files, skips comments',
      () {
    expect(declaredAssetFiles(root), [
      'assets/hello.txt',
      'assets/icons/a.png',
      'assets/icons/b.png',
    ]);
  });

  test('a declared-but-missing asset refuses naming the path', () {
    File('$root/pubspec.yaml').writeAsStringSync('''
flutter:
  assets:
    - assets/gone.png
''');
    expect(() => declaredAssetFiles(root),
        throwsA(isA<AssetSpecException>()));
  });

  test('no assets section is an empty watch set, not an error', () {
    File('$root/pubspec.yaml').writeAsStringSync('''
flutter:
  uses-material-design: true
''');
    expect(declaredAssetFiles(root), isEmpty);
  });

  test('declaredShaderFiles reads the shaders: section, not assets:', () {
    Directory('$root/shaders').createSync();
    File('$root/shaders/hello.frag').writeAsStringSync('#version 320 es');
    File('$root/pubspec.yaml').writeAsStringSync('''
flutter:
  assets:
    - assets/hello.txt
  shaders:
    - shaders/hello.frag
''');
    expect(declaredShaderFiles(root), ['shaders/hello.frag']);
    expect(declaredAssetFiles(root), ['assets/hello.txt'],
        reason: 'the sections are independent');
  });

  test('findFlutterAssetsDir resolves macOS Debug flutter_assets', () {
    final dir = '$root/build/macos/Build/Products/Debug'
        '/runner.app/Contents/Frameworks/App.framework'
        '/Versions/A/Resources/flutter_assets';
    Directory(dir).createSync(recursive: true);
    expect(
      findFlutterAssetsDir(root, desktopPlatform: 'macos'),
      dir,
    );
  });

  test('findFlutterAssetsDir resolves Linux debug flutter_assets', () {
    final linuxDir = '$root/build/linux/x64/debug/bundle/data/flutter_assets';
    Directory(linuxDir).createSync(recursive: true);
    expect(
      findFlutterAssetsDir(root, desktopPlatform: 'linux'),
      linuxDir,
    );
  });

  test('ignores Release when buildMode is debug', () {
    Directory(
      '$root/build/macos/Build/Products/Release'
      '/rel.app/Contents/Frameworks/App.framework'
      '/Versions/A/Resources/flutter_assets',
    ).createSync(recursive: true);
    final debugDir = '$root/build/macos/Build/Products/Debug'
        '/dbg.app/Contents/Frameworks/App.framework'
        '/Versions/A/Resources/flutter_assets';
    Directory(debugDir).createSync(recursive: true);
    expect(findFlutterAssetsDir(root, desktopPlatform: 'macos'), debugDir);
  });

  test('both desktop trees without platform refuses ambiguity', () {
    Directory(
      '$root/build/macos/Build/Products/Debug'
      '/mac.app/Contents/Frameworks/App.framework'
      '/Versions/A/Resources/flutter_assets',
    ).createSync(recursive: true);
    Directory('$root/build/linux/x64/debug/bundle/data/flutter_assets')
        .createSync(recursive: true);
    expect(
      () => findFlutterAssetsDir(root),
      throwsA(
        isA<AssetSpecException>().having(
          (e) => e.message,
          'message',
          contains('ambiguous desktop flutter_assets'),
        ),
      ),
    );
  });

  test(
    'desktopPlatform macos ignores newer Linux tree (misleading mtimes)',
    () async {
      final macDir = '$root/build/macos/Build/Products/Debug'
          '/mac.app/Contents/Frameworks/App.framework'
          '/Versions/A/Resources/flutter_assets';
      Directory(macDir).createSync(recursive: true);
      final linuxDir = '$root/build/linux/x64/debug/bundle/data/flutter_assets';
      Directory(linuxDir).createSync(recursive: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File('$linuxDir/.mtime-sentinel')
        ..createSync()
        ..setLastModifiedSync(DateTime.utc(2030));
      expect(
        findFlutterAssetsDir(root, desktopPlatform: 'macos'),
        macDir,
        reason: 'must not pick Linux assets for a macOS dev session',
      );
    },
  );

  test('unsupported desktopPlatform refuses explicitly', () {
    expect(
      () => findFlutterAssetsDir(root, desktopPlatform: 'windows'),
      throwsA(isA<AssetSpecException>()),
    );
  });

  test('multiple macOS Debug products refuses ambiguity with sorted paths', () {
    for (final name in ['a', 'b']) {
      Directory(
        '$root/build/macos/Build/Products/Debug'
        '/$name.app/Contents/Frameworks/App.framework'
        '/Versions/A/Resources/flutter_assets',
      ).createSync(recursive: true);
    }
    expect(
      () => findFlutterAssetsDir(root, desktopPlatform: 'macos'),
      throwsA(
        isA<AssetSpecException>().having(
          (e) => e.message,
          'message',
          matches(RegExp(r'a\.app.*b\.app|b\.app.*a\.app')),
        ),
      ),
    );
  });
}
