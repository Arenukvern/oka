import 'package:oka/src/build/host_codegen.dart';
import 'package:test/test.dart';

void main() {
  group('generateMainActivityJava', () {
    test('extends FlutterActivity', () {
      final src = generateMainActivityJava('com.example.example');
      expect(src, contains('package com.example.example;'));
      expect(src, contains('extends FlutterActivity'));
      expect(src, contains('import io.flutter.embedding.android.FlutterActivity;'));
    });

    test('rejects invalid package', () {
      expect(() => generateMainActivityJava('invalid'), throwsArgumentError);
    });

    test('mainActivityRelativePath', () {
      expect(
        mainActivityRelativePath('com.example.app'),
        'com/example/app/MainActivity.java',
      );
    });
  });

  group('generatePluginRegistrantJava', () {
    test('empty plugins is no-op registrant', () {
      final src = generatePluginRegistrantJava(const []);
      expect(src, contains('package io.flutter.plugins;'));
      expect(src, contains('registerWith'));
      expect(src, contains('No plugins registered'));
      expect(src, isNot(contains('getPlugins().add')));
    });

    test('includes discovered plugin classes', () {
      final src = generatePluginRegistrantJava([
        const PluginRegistration(
          className: 'io.flutter.plugins.pathprovider.PathProviderPlugin',
          name: 'path_provider',
        ),
      ]);
      expect(
        src,
        contains(
          'flutterEngine.getPlugins().add(new io.flutter.plugins.pathprovider.PathProviderPlugin())',
        ),
      );
      expect(src, contains('path_provider'));
    });
  });

  group('generateAndroidManifestXml', () {
    test('embedding v2 meta-data and activity', () {
      final xml = generateAndroidManifestXml(
        packageName: 'com.example.example',
        label: 'Example',
        minSdk: '21',
        targetSdk: '34',
      );
      expect(xml, contains('package="com.example.example"'));
      expect(xml, contains('flutterEmbedding'));
      expect(xml, contains('android:value="2"'));
      expect(xml, contains('.MainActivity'));
      expect(xml, contains('android.permission.INTERNET'));
    });
  });
}
