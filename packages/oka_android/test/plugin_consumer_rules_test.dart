import 'dart:io';

import 'package:oka_android/src/build/consumer_rules.dart';
import 'package:oka_android/src/build/plugin_consumer_rules.dart';
import 'package:oka_android/src/pipeline/steps/tool_steps.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Consumer ProGuard rules declared by *source* Flutter plugins
/// (`consumerProguardFiles` in the plugin's Gradle script) — ADR-0051.
///
/// A source plugin ships no AAR, so the declaration in its Gradle script is
/// the only place its consumer rules exist. `flutter_inappwebview_android`
/// (1.1.3) declares `consumerProguardFiles 'proguard-rules.pro'` with the
/// `@JavascriptInterface` keep rules; `file_picker` declares the Tika/StAX
/// rules. Missing them means the shrinker may strip a public API.
void main() {
  group('parseConsumerProguardFiles', () {
    test('reads the Groovy declaration Flutter plugins use', () {
      const gradle = '''
android {
    defaultConfig {
        minSdkVersion 19
        consumerProguardFiles 'proguard-rules.pro'
    }
}
''';
      expect(parseConsumerProguardFiles(gradle), ['proguard-rules.pro']);
    });

    test('reads the Kotlin DSL declaration', () {
      const gradle = '''
android {
    defaultConfig {
        consumerProguardFiles("proguard-rules.pro")
    }
}
''';
      expect(parseConsumerProguardFiles(gradle), ['proguard-rules.pro']);
    });

    test('reads the singular `consumerProguardFile` form', () {
      const gradle = '''
android {
    consumerProguardFile("rules.pro")
}
''';
      expect(parseConsumerProguardFiles(gradle), ['rules.pro']);
    });

    test('unwraps a `file(...)` argument', () {
      const gradle = '''
android {
    defaultConfig {
        consumerProguardFiles file('proguard-rules.pro')
    }
}
''';
      expect(parseConsumerProguardFiles(gradle), ['proguard-rules.pro']);
    });

    test('a declaration does not swallow quoted strings that follow it', () {
      // Regression: the parenthesised form must end at its own closing
      // parenthesis — otherwise every quoted string later in the script
      // (e.g. `disable += "InvalidPackage"`) is read as a rule file.
      const gradle = '''
android {
    defaultConfig {
        consumerProguardFiles("proguard-rules.pro")
    }
    lint {
        disable += "InvalidPackage"
    }
    kotlinOptions {
        setProperty("jvmTarget", "17")
    }
}
''';
      expect(parseConsumerProguardFiles(gradle), ['proguard-rules.pro']);
    });

    test("ignores the library's own proguardFiles declaration", () {
      // `proguardFiles` describes how the library itself is minified; AGP
      // does not export it to consumers.
      const gradle = '''
android {
    buildTypes {
        release {
            minifyEnabled true
            proguardFiles getDefaultProguardFile('proguard-android.txt'), 'proguard-rules.pro'
        }
    }
}
''';
      expect(parseConsumerProguardFiles(gradle), isEmpty);
    });

    test('collects several declarations in order, without duplicates', () {
      const gradle = '''
android {
    defaultConfig {
        consumerProguardFiles 'a.pro', 'b.pro'
    }
    buildTypes {
        release {
            consumerProguardFiles 'b.pro'
        }
    }
}
''';
      expect(parseConsumerProguardFiles(gradle), ['a.pro', 'b.pro']);
    });
  });

  group('discoverPluginConsumerRuleFiles', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('oka_plugin_rules_');
    });

    tearDown(() => temp.delete(recursive: true));

    test('resolves a declared file against the plugin module dir', () {
      final module = Directory(p.join(temp.path, 'android'))
        ..createSync(recursive: true);
      File(p.join(module.path, 'build.gradle')).writeAsStringSync(
        "android { defaultConfig { consumerProguardFiles 'proguard-rules.pro' } }",
      );
      File(p.join(module.path, 'proguard-rules.pro')).writeAsStringSync(
        '-keep class com.example.** { *; }\n',
      );

      final discovery = discoverPluginConsumerRuleFiles(
        pluginName: 'demo_plugin',
        moduleDir: module.path,
      );
      expect(discovery.files, [p.join(module.path, 'proguard-rules.pro')]);
      expect(discovery.missing, isEmpty);
    });

    test('reports a declared file that does not exist instead of dropping it',
        () {
      final module = Directory(p.join(temp.path, 'android'))
        ..createSync(recursive: true);
      File(p.join(module.path, 'build.gradle.kts')).writeAsStringSync(
        'android { consumerProguardFiles("missing.pro") }',
      );

      final discovery = discoverPluginConsumerRuleFiles(
        pluginName: 'demo_plugin',
        moduleDir: module.path,
      );
      expect(discovery.files, isEmpty);
      expect(discovery.missing, [p.join(module.path, 'missing.pro')]);
    });

    test('a plugin without a Gradle script declares nothing', () {
      final module = Directory(p.join(temp.path, 'android'))
        ..createSync(recursive: true);
      final discovery = discoverPluginConsumerRuleFiles(
        pluginName: 'demo_plugin',
        moduleDir: module.path,
      );
      expect(discovery.isEmpty, isTrue);
    });
  });

  group('collectPluginConsumerRuleFiles', () {
    test('orders by plugin name, then by path', () {
      const a = PluginConsumerRuleDiscovery(
        pluginName: 'b_plugin',
        files: ['/tmp/b.pro'],
      );
      const b = PluginConsumerRuleDiscovery(
        pluginName: 'a_plugin',
        files: ['/tmp/a2.pro', '/tmp/a1.pro'],
      );
      final collected = collectPluginConsumerRuleFiles([a, b]);
      expect(
        collected.map((f) => '${f.pluginName}:${p.basename(f.path)}').toList(),
        ['a_plugin:a1.pro', 'a_plugin:a2.pro', 'b_plugin:b.pro'],
      );
    });
  });

  group('pluginConsumerRuleFiles (compile step)', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('oka_plugin_step_');
    });

    tearDown(() => temp.delete(recursive: true));

    test('discovers the declared rule file of a packaged plugin', () {
      final module = Directory(p.join(temp.path, 'android'))
        ..createSync(recursive: true);
      File(p.join(module.path, 'build.gradle')).writeAsStringSync(
        "android { defaultConfig { consumerProguardFiles 'proguard-rules.pro' } }",
      );
      File(p.join(module.path, 'proguard-rules.pro')).writeAsStringSync(
        '-keep class com.example.** { *; }\n',
      );

      final discovered = pluginConsumerRuleFiles([
        (name: 'demo_plugin', path: temp.path),
      ]);
      expect(discovered.files, hasLength(1));
      expect(discovered.files.single.pluginName, 'demo_plugin');
      expect(discovered.files.single.path, endsWith('proguard-rules.pro'));
      expect(discovered.missing, isEmpty);
    });

    test('a missing declaration is reported, not dropped', () {
      final module = Directory(p.join(temp.path, 'android'))
        ..createSync(recursive: true);
      File(p.join(module.path, 'build.gradle')).writeAsStringSync(
        "android { defaultConfig { consumerProguardFiles 'gone.pro' } }",
      );

      final discovered = pluginConsumerRuleFiles([
        (name: 'demo_plugin', path: temp.path),
      ]);
      expect(discovered.files, isEmpty);
      expect(discovered.missing, hasLength(1));
      expect(discovered.missing.single, contains('demo_plugin'));
    });
  });

  group('collectConsumerProguardRuleFiles', () {
    test('reads the declared file and attributes it to the plugin', () {
      final temp = Directory.systemTemp.createTempSync('oka_plugin_rules_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'proguard-rules.pro'))
        ..writeAsStringSync(
          '-keepattributes *JavascriptInterface*\n'
          '-keepclassmembers class * {\n'
          '    @android.webkit.JavascriptInterface <methods>;\n'
          '}\n',
        );

      final rules = collectConsumerProguardRuleFiles([
        PluginConsumerRuleFile(
          pluginName: 'flutter_inappwebview_android',
          path: file.path,
        ),
      ]);
      expect(rules, hasLength(1));
      expect(rules.single.coordinate, 'flutter_inappwebview_android');
      expect(rules.single.source, file.path);
      expect(rules.single.rules, contains('JavascriptInterface'));

      final rendered = renderConsumerProguardRules(rules);
      expect(rendered, contains('# --- flutter_inappwebview_android ---'));
      expect(rendered, contains('JavascriptInterface'));
    });

    test('an empty or missing file contributes nothing', () {
      final temp = Directory.systemTemp.createTempSync('oka_plugin_rules_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final empty = File(p.join(temp.path, 'empty.pro'))..writeAsStringSync('');
      final rules = collectConsumerProguardRuleFiles([
        PluginConsumerRuleFile(pluginName: 'a', path: empty.path),
        PluginConsumerRuleFile(
          pluginName: 'b',
          path: p.join(temp.path, 'absent.pro'),
        ),
      ]);
      expect(rules, isEmpty);
    });
  });
}
