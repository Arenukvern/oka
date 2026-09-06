import 'dart:io';

import 'package:oka_android/src/build/host_codegen.dart';
import 'package:oka_android/src/build/plugin_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('parseFlutterPluginsDependenciesJson', () {
    test('parses android plugins list', () {
      const json = '''
{
  "plugins": {
    "android": [
      {"name": "path_provider_android", "path": "/pub/path_provider_android"},
      {"name": "shared_preferences_android", "path": "/pub/shared_preferences_android"}
    ],
    "ios": [
      {"name": "path_provider_foundation", "path": "/pub/ppf"}
    ]
  }
}
''';
      final result = parseFlutterPluginsDependenciesJson(json);
      expect(result.plugins.length, greaterThanOrEqualTo(2));
      expect(
        result.androidPlugins.map((p) => p.name),
        containsAll(['path_provider_android', 'shared_preferences_android']),
      );
    });

    test('empty plugins', () {
      final result = parseFlutterPluginsDependenciesJson('{"plugins":{}}');
      expect(result.plugins, isEmpty);
      expect(result.hasUnsupported, isFalse);
    });
  });

  group('parseFlutterPluginsFile', () {
    test('legacy name=path lines', () {
      final list = parseFlutterPluginsFile('''
# comment
path_provider=/tmp/path_provider
url_launcher=/tmp/url_launcher
''');
      expect(list.length, 2);
      expect(list.first.name, 'path_provider');
      expect(list.first.path, '/tmp/path_provider');
    });
  });

  group('PluginDiscovery', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_plugins_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('discovers zero plugins when files missing', () async {
      final d = PluginDiscovery();
      final result = await d.discover(tmp.path);
      expect(result.plugins, isEmpty);
      final regs = d.toRegistrations(result);
      expect(regs, isEmpty);
      final java = generatePluginRegistrantJava(regs);
      expect(java, contains('No plugins registered'));
    });

    test('discovers plugins from .flutter-plugins-dependencies', () async {
      await File(p.join(tmp.path, '.flutter-plugins-dependencies')).writeAsString('''
{
  "plugins": {
    "android": [
      {"name": "demo_plugin", "path": "${tmp.path}/demo_plugin"}
    ]
  }
}
''');
      // Plugin pubspec with android class
      final pluginDir = Directory(p.join(tmp.path, 'demo_plugin'));
      await pluginDir.create();
      await File(p.join(pluginDir.path, 'pubspec.yaml')).writeAsString('''
name: demo_plugin
flutter:
  plugin:
    platforms:
      android:
        package: com.example.demo
        pluginClass: DemoPlugin
''');

      final d = PluginDiscovery();
      final result = await d.discover(tmp.path);
      expect(result.androidPlugins, isNotEmpty);
      final enriched = result.androidPlugins.first;
      expect(enriched.androidPackage, 'com.example.demo');
      expect(enriched.pluginClass, 'DemoPlugin');
      expect(enriched.qualifiedClass, 'com.example.demo.DemoPlugin');

      final regs = d.toRegistrations(result);
      expect(regs.single.className, 'com.example.demo.DemoPlugin');
    });

    test('ensureSupported throws on unsupported', () {
      final d = PluginDiscovery();
      const result = PluginDiscoveryResult(
        plugins: [
          DiscoveredPlugin(
            name: 'firebase_core',
            path: '/x',
            hasAndroid: true,
            unsupportedNative: true,
            unsupportedReason: 'uses google-services',
          ),
        ],
        unsupported: [
          DiscoveredPlugin(
            name: 'firebase_core',
            path: '/x',
            hasAndroid: true,
            unsupportedNative: true,
            unsupportedReason: 'uses google-services',
          ),
        ],
      );
      expect(
        () => d.ensureSupported(result),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'msg',
          contains('Unsupported Flutter plugins'),
        )),
      );
    });

    test('detects unsupported AGP google-services plugins', () async {
      await File(p.join(tmp.path, '.flutter-plugins-dependencies')).writeAsString('''
{
  "plugins": {
    "android": [
      {"name": "firebase_heavy", "path": "${tmp.path}/firebase_heavy"}
    ]
  }
}
''');
      final pluginDir = Directory(p.join(tmp.path, 'firebase_heavy', 'android'));
      await pluginDir.create(recursive: true);
      await File(p.join(tmp.path, 'firebase_heavy', 'pubspec.yaml')).writeAsString('''
name: firebase_heavy
flutter:
  plugin:
    platforms:
      android:
        package: com.example.firebase_heavy
        pluginClass: FirebaseHeavyPlugin
''');
      // CMake alone is packable via NDK; AGP google-services is not.
      await File(p.join(pluginDir.path, 'build.gradle')).writeAsString('''
apply plugin: 'com.google.gms.google-services'
android {
  // ...
}
''');

      final d = PluginDiscovery();
      final result = await d.discover(tmp.path);
      expect(result.hasUnsupported, isTrue);
      expect(result.unsupported.first.name, 'firebase_heavy');
    });
  });
}
