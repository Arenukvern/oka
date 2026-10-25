import 'dart:io';

import 'package:oka_android/src/pipeline/steps/host_steps.dart';
import 'package:test/test.dart';

void main() {
  test('missing store jar invalidates otherwise unchanged packaging', () async {
    final temp = await Directory.systemTemp.createTemp('oka-plugin-cache-');
    addTearDown(() => temp.delete(recursive: true));
    final jar = await File('${temp.path}/activity.jar')
        .writeAsString('payload');
    final resources = await Directory('${temp.path}/res').create();
    final cached = <String, dynamic>{
      'plugin_names': ['browser'],
      'jars_browser': [jar.path],
      'res_browser': [resources.path],
    };
    expect(pluginPackagingCacheOutputsExist(cached), isTrue);
    await jar.delete();
    expect(pluginPackagingCacheOutputsExist(cached), isFalse);
    await jar.writeAsString('restored');
    expect(pluginPackagingCacheOutputsExist(cached), isTrue);
    await resources.delete();
    expect(pluginPackagingCacheOutputsExist(cached), isFalse);
  });

  test('missing extracted native invalidates cache', () {
    expect(
      pluginPackagingCacheOutputsExist({
        'plugin_names': <String>[],
        'natives': {
          'arm64-v8a': ['/missing/libbrowser.so'],
        },
      }),
      isFalse,
    );
  });
}
