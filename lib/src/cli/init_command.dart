import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../ai/ai_agent.dart';
import '../ai/ai_client.dart';

/// Init command to create oka.yaml from existing Gradle project
class InitCommand {
  Future<void> run(List<String> args) async {
    print('🚀 Initializing Oka configuration...\n');

    // Check if this is a Flutter project
    final pubspecFile = File('pubspec.yaml');
    if (!await pubspecFile.exists()) {
      print('❌ Not a Flutter project (pubspec.yaml not found)');
      print('   Run this command from the root of a Flutter project');
      exit(1);
    }

    // Check if oka.yaml already exists
    final okaYamlFile = File('oka.yaml');
    if (await okaYamlFile.exists()) {
      print('⚠️  oka.yaml already exists');
      stdout.write('   Overwrite? (y/N): ');
      final response = stdin.readLineSync()?.toLowerCase();
      if (response != 'y' && response != 'yes') {
        print('   Cancelled');
        exit(0);
      }
    }

    // Read pubspec.yaml for project info
    final pubspecContent = await pubspecFile.readAsString();
    final pubspec = loadYaml(pubspecContent) as Map<dynamic, dynamic>;
    final projectName = (pubspec['name'] as String?) ?? 'app';
    final projectVersion = (pubspec['version'] as String?) ?? '1.0.0';

    print('📦 Project: $projectName v$projectVersion');

    // Check for existing Gradle configuration
    final gradleFile = File(p.join('android', 'app', 'build.gradle'));

    if (await gradleFile.exists()) {
      print('📄 Found build.gradle, converting to oka.yaml...\n');

      final gradleContent = await gradleFile.readAsString();

      // Initialize AI agent
      final home = Platform.environment['HOME'] ?? '';
      final cacheDir = p.join(home, '.oka_cache', 'ai');
      final client = AiClientFactory.create();
      final aiAgent = OkaAiAgent(client, cacheDir);

      print('🤖 Using AI to convert Gradle configuration...');
      print('   This may take a moment...\n');

      try {
        final config = await aiAgent.convertGradleToOka(
          gradleContent,
          Directory.current.path,
        );

        // Create oka.yaml with converted config
        final okaYaml = {
          'name': projectName,
          'version': projectVersion,
          'android': config.android.toJson(),
          'dependencies': config.dependencies.map((d) => d.toJson()).toList(),
        };

        // Write oka.yaml
        await okaYamlFile.writeAsString(_toYamlString(okaYaml));

        print('✅ oka.yaml created successfully!');
        print('');
        print('📋 Configuration summary:');
        print('   Package: ${config.android.packageName}');
        print('   Min SDK: ${config.android.minSdk}');
        print('   Target SDK: ${config.android.targetSdk}');
        print('   Dependencies: ${config.dependencies.length}');
        print('');
        print('Next steps:');
        print('  1. Review oka.yaml and adjust if needed');
        print('  2. Run "oka build apk" to build your app');
        print('  3. Run "oka dev" to start development mode');
      } catch (e) {
        print('❌ Failed to convert Gradle configuration: $e');
        print('');
        print('💡 Creating default oka.yaml instead...');
        await _createDefaultConfig(projectName, projectVersion);
      }
    } else {
      print('📄 No build.gradle found, creating default configuration...\n');
      await _createDefaultConfig(projectName, projectVersion);
    }
  }

  Future<void> _createDefaultConfig(String name, String version) async {
    final okaYaml = {
      'name': name,
      'version': version,
      'android': {
        'compile_sdk': '34',
        'min_sdk': '21',
        'target_sdk': '34',
        'package_name': 'com.example.$name',
        'version_code': 1,
        'version_name': version,
        'source_dirs': ['src/main/java', 'src/main/kotlin'],
        'res_dirs': ['src/main/res'],
        'abis': ['arm64-v8a', 'armeabi-v7a'],
      },
      'dependencies': <Map<String, dynamic>>[],
    };

    final okaYamlFile = File('oka.yaml');
    await okaYamlFile.writeAsString(_toYamlString(okaYaml));

    print('✅ Default oka.yaml created!');
    print('');
    print('📋 Please edit oka.yaml to add:');
    print('   - Correct package name');
    print('   - Android dependencies');
    print('   - Build configuration');
  }

  String _toYamlString(Map<String, dynamic> data) {
    final buffer = StringBuffer();
    _writeYaml(buffer, data, 0);
    return buffer.toString();
  }

  void _writeYaml(StringBuffer buffer, dynamic data, int indent) {
    final spaces = '  ' * indent;

    if (data is Map) {
      data.forEach((key, value) {
        if (value is Map || value is List) {
          buffer.writeln('$spaces$key:');
          _writeYaml(buffer, value, indent + 1);
        } else {
          buffer.writeln('$spaces$key: $value');
        }
      });
    } else if (data is List) {
      for (final item in data) {
        if (item is Map) {
          buffer.writeln('$spaces-');
          _writeYaml(buffer, item, indent + 1);
        } else {
          buffer.writeln('$spaces- $item');
        }
      }
    }
  }
}
