import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';


void main() {
  group('ExtraAssetsStep', () {
    test('parse handles maps and bare strings', () {
      final entries = ExtraAssetsStep.parse([
        {'from': 'a/b.txt', 'to': 'x/b.txt'},
        'c/d.json',
      ]);
      expect(entries.length, 2);
      expect(entries[0].from, 'a/b.txt');
      expect(entries[0].to, 'x/b.txt');
      expect(entries[1].from, 'c/d.json');
      expect(entries[1].to, 'd.json');
    });

    test('copies file and dir into flutter_assets', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_extra_assets_');
      addTearDown(() => tmp.delete(recursive: true));

      // Project layout
      final proj = Directory(p.join(tmp.path, 'proj'));
      Directory(p.join(proj.path, 'assets')).createSync(recursive: true);
      File(p.join(proj.path, 'assets', 'hello.txt')).writeAsStringSync('hi');
      File(p.join(proj.path, 'gen.json')).writeAsStringSync('{}');
      final assetsDir = p.join(tmp.path, 'out', 'flutter_assets');
      Directory(assetsDir).createSync(recursive: true);

      final ctx = BuildContext.fromJson({
        'project_path': proj.path,
        'build_dir': p.join(tmp.path, 'build'),
        'mode': 'debug',
        'config': OkaConfig.empty.toJson(),
        'cache_dir': '',
        'temp_dir': '',
        'flutter_sdk_path': '',
        'android_sdk_path': '',
        'build_timestamp': 0,
        'verbose': false,
        'flavor': '',
        'target_abi': '',
        'build_aab': false,
      });
      final state = PipelineState()..flutterAssetsDir = assetsDir;

      final step = ExtraAssetsStep([
        (from: 'assets', to: 'assets'),
        (from: 'gen.json', to: 'generated-config.json'),
      ]);
      final result = await step.run(ctx, state);
      expect(result.ok, isTrue, reason: result.error);

      expect(
        File(p.join(assetsDir, 'assets', 'hello.txt')).readAsStringSync(),
        'hi',
      );
      expect(
        File(p.join(assetsDir, 'generated-config.json')).existsSync(),
        isTrue,
      );
    });

    test('fails on missing source', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_extra_miss_');
      addTearDown(() => tmp.delete(recursive: true));
      final ctx = BuildContext.fromJson({
        'project_path': tmp.path,
        'build_dir': p.join(tmp.path, 'build'),
        'mode': 'debug',
        'config': OkaConfig.empty.toJson(),
        'cache_dir': '',
        'temp_dir': '',
        'flutter_sdk_path': '',
        'android_sdk_path': '',
        'build_timestamp': 0,
        'verbose': false,
        'flavor': '',
        'target_abi': '',
        'build_aab': false,
      });
      final state = PipelineState()..flutterAssetsDir = p.join(tmp.path, 'fa');
      final result = await ExtraAssetsStep([
        (from: 'missing.txt', to: 'm.txt'),
      ]).run(ctx, state);
      expect(result.ok, isFalse);
      expect(result.error, contains('not found'));
    });
  });

  group('DeeplinkConfig', () {
    test('parses scheme/host/pathPrefix', () {
      final c = DeeplinkConfig.fromMap({
        'scheme': 'https',
        'host': 'example.com',
        'pathPrefix': '/app',
      });
      expect(c, isNotNull);
      expect(c!.intentFilterXml, contains('android:host="example.com"'));
      expect(c.intentFilterXml, contains('android:pathPrefix="/app"'));
      expect(c.intentFilterXml, contains('autoVerify="true"'));
    });

    test('rejects missing scheme', () {
      expect(DeeplinkConfig.fromMap({'host': 'example.com'}), isNull);
    });

    test('allows scheme-only deeplinks (custom schemes, no host)', () {
      final c = DeeplinkConfig.fromMap({'scheme': 'dev.xsoulspace.lastanswer'});
      expect(c, isNotNull);
      expect(c!.host, isEmpty);
      expect(c.intentFilterXml, contains('android:scheme="dev.xsoulspace.lastanswer"'));
      expect(c.intentFilterXml, isNot(contains('android:host')));
    });
  });
}
