import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:oka/src/build/launcher_icon.dart';

void main() {
  group('stageLauncherIcons', () {
    late Directory tmp;
    late String resDir;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_icon_');
      resDir = p.join(tmp.path, 'res');
    });

    tearDown(() => tmp.delete(recursive: true));

    test('writes adaptive icon set with default glyph', () async {
      final icons = await stageLauncherIcons(
        resDir,
        const IconConfig(),
        projectPath: tmp.path,
      );

      expect(icons.manifestRef, '@mipmap/ic_launcher');
      expect(icons.written, contains('mipmap-anydpi-v26/ic_launcher.xml'));
      expect(icons.written, contains('drawable/ic_launcher_foreground.xml'));
      expect(icons.written, contains('values/ic_launcher_background.xml'));

      final adaptive = File(
        p.join(resDir, 'mipmap-anydpi-v26', 'ic_launcher.xml'),
      ).readAsStringSync();
      expect(adaptive, contains('<adaptive-icon'));
      expect(adaptive, contains('@color/ic_launcher_background'));
      expect(adaptive, contains('@drawable/ic_launcher_foreground'));
      expect(adaptive, isNot(contains('monochrome')));

      final fg = File(
        p.join(resDir, 'drawable', 'ic_launcher_foreground.xml'),
      ).readAsStringSync();
      expect(fg, contains('<vector'));
    });

    test('includes monochrome when configured', () async {
      final monoSrc = File(p.join(tmp.path, 'mono.xml'))
        ..writeAsStringSync('<vector/>');
      final icons = await stageLauncherIcons(
        resDir,
        IconConfig(monochrome: 'mono.xml'),
        projectPath: tmp.path,
      );

      expect(icons.written, contains('drawable/ic_launcher_monochrome.xml'));
      final adaptive = File(
        p.join(resDir, 'mipmap-anydpi-v26', 'ic_launcher.xml'),
      ).readAsStringSync();
      expect(adaptive, contains('<monochrome'));
      expect(monoSrc.existsSync(), isTrue);
    });

    test('uses custom vector foreground', () async {
      File(
        p.join(tmp.path, 'custom_fg.xml'),
      ).writeAsStringSync('<vector android:width="108dp"/><!-- custom -->');

      await stageLauncherIcons(
        resDir,
        const IconConfig(vector: 'custom_fg.xml'),
        projectPath: tmp.path,
      );

      final fg = File(
        p.join(resDir, 'drawable', 'ic_launcher_foreground.xml'),
      ).readAsStringSync();
      expect(fg, contains('custom'));
    });

    test('fails on missing vector source', () async {
      expect(
        () => stageLauncherIcons(
          resDir,
          const IconConfig(vector: 'nope.xml'),
          projectPath: tmp.path,
        ),
        throwsException,
      );
    });

    test('rejects invalid background color', () async {
      expect(
        () => stageLauncherIcons(
          resDir,
          const IconConfig(backgroundColor: 'green'),
          projectPath: tmp.path,
        ),
        throwsException,
      );
    });

    test('accepts resource ref as background', () async {
      final icons = await stageLauncherIcons(
        resDir,
        const IconConfig(backgroundColor: '@color/my_bg'),
        projectPath: tmp.path,
      );
      expect(icons.manifestRef, '@mipmap/ic_launcher');
      final bg = File(
        p.join(resDir, 'values', 'ic_launcher_background.xml'),
      ).readAsStringSync();
      expect(bg, contains('@color/my_bg'));
    });
  });

  group('defaultForegroundVector', () {
    test('is a valid vector drawable with safe-zone content', () {
      final v = defaultForegroundVector();
      expect(v, contains('android:viewportWidth="108"'));
      expect(v, contains('android:viewportHeight="108"'));
      expect(v, contains('<path'));
    });
  });
}
