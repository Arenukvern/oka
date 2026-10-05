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

  test('findFlutterAssetsDir picks the newest build product', () async {
    expect(findFlutterAssetsDir(root), isNull,
        reason: 'no build products yet');
    // Dir mtime = last child creation: create `new` strictly after `old`.
    for (final stamp in ['old', 'new']) {
      Directory('$root/build/macos/Build/Products/Debug'
              '/app_$stamp.app/Contents/Frameworks/App.framework'
              '/Versions/A/Resources/flutter_assets/assets')
          .createSync(recursive: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    expect(findFlutterAssetsDir(root), endsWith('app_new.app'
        '/Contents/Frameworks/App.framework/Versions/A/Resources'
        '/flutter_assets'));
  });
}
