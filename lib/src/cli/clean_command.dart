import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

/// Clean command to clear build caches
class CleanCommand {
  Future<void> run(List<String> args) async {
    final parser = ArgParser()
      ..addFlag('full', negatable: false, help: 'Clear dependency cache too')
      ..addFlag('ai-cache',
          negatable: false, help: 'Clear AI conversion cache');

    final results = parser.parse(args);

    print('🧹 Cleaning build cache...');

    // Clean local build cache
    final buildCache = Directory('.oka_cache');
    if (await buildCache.exists()) {
      await buildCache.delete(recursive: true);
      print('  ✅ Removed .oka_cache/');
    } else {
      print('  ℹ️  .oka_cache/ not found');
    }

    // Clean full cache (including dependencies)
    if (results['full'] as bool) {
      print('\n🧹 Cleaning dependency cache...');
      final home = Platform.environment['HOME'] ?? '';
      final depCache = Directory(p.join(home, '.oka_cache', 'maven'));

      if (await depCache.exists()) {
        await depCache.delete(recursive: true);
        print('  ✅ Removed ~/.oka_cache/maven/');
      } else {
        print('  ℹ️  ~/.oka_cache/maven/ not found');
      }
    }

    // Clean AI cache
    if (results['ai-cache'] as bool) {
      print('\n🧹 Cleaning AI conversion cache...');
      final home = Platform.environment['HOME'] ?? '';
      final aiCache = Directory(p.join(home, '.oka_cache', 'ai'));

      if (await aiCache.exists()) {
        await aiCache.delete(recursive: true);
        print('  ✅ Removed ~/.oka_cache/ai/');
      } else {
        print('  ℹ️  ~/.oka_cache/ai/ not found');
      }
    }

    print('\n✅ Clean complete!');
  }
}
