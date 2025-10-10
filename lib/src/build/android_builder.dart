import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/build_context.dart';
import 'sdk_locator.dart';

/// Android APK builder that orchestrates the build pipeline
class AndroidBuilder {
  final SdkLocator _sdkLocator;
  final bool _verbose;

  AndroidBuilder(this._sdkLocator, {bool verbose = false}) : _verbose = verbose;

  /// Build APK from build context
  Future<BuildArtifact> buildApk(BuildContext ctx) async {
    final startTime = DateTime.now();

    try {
      print('🔨 Building ${ctx.mode.name} APK...');

      // Validate tools
      print('Validating Android SDK tools...');
      await _sdkLocator.validateTools();

      // Create build directories
      await _createBuildDirectories(ctx);

      // Compile resources
      print('📦 Compiling resources...');
      await compileResources(ctx);

      // Compile Kotlin/Java
      print('☕ Compiling Kotlin/Java sources...');
      await compileKotlin(ctx);

      // Convert to DEX
      print('🔄 Converting to DEX...');
      await convertToDex(ctx);

      // Package APK
      print('📱 Packaging APK...');
      await packageApk(ctx);

      // Sign APK
      print('🔐 Signing APK...');
      await signApk(ctx);

      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      final apkPath = p.join(ctx.buildDir, 'app-${ctx.mode.name}.apk');
      final apkFile = File(apkPath);
      final size = await apkFile.length();

      print('✅ Build successful in ${duration.inSeconds}s');
      print('📍 APK: $apkPath');
      print('📊 Size: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');

      return BuildArtifact.fromJson({
        'apk_path': apkPath,
        'size': size,
        'build_duration': duration.inMilliseconds,
        'timestamp': endTime.millisecondsSinceEpoch,
        'success': true,
      });
    } catch (e, stackTrace) {
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      print('❌ Build failed: $e');
      if (_verbose) {
        print(stackTrace);
      }

      return BuildArtifact.fromJson({
        'apk_path': '',
        'size': 0,
        'build_duration': duration.inMilliseconds,
        'timestamp': endTime.millisecondsSinceEpoch,
        'success': false,
        'error': e.toString(),
      });
    }
  }

  /// Compile Android resources using aapt2
  Future<void> compileResources(BuildContext ctx) async {
    final aapt2 = await _sdkLocator.findAapt2();
    final androidSdk = await _sdkLocator.findAndroidSdk();

    final resDir =
        p.join(ctx.projectPath, 'android', 'app', 'src', 'main', 'res');
    final compiledResDir = p.join(ctx.buildDir, 'compiled_res');
    await Directory(compiledResDir).create(recursive: true);

    // Compile resources
    final compileResult = await Process.run(
      aapt2,
      [
        'compile',
        '--dir',
        resDir,
        '-o',
        compiledResDir,
      ],
    );

    if (compileResult.exitCode != 0) {
      throw Exception('aapt2 compile failed: ${compileResult.stderr}');
    }

    // Link resources
    final androidJar = p.join(
      androidSdk,
      'platforms',
      'android-${ctx.config.android.compileSdk}',
      'android.jar',
    );

    final manifestPath = p.join(ctx.buildDir, 'AndroidManifest.xml');
    final linkedResPath = p.join(ctx.buildDir, 'resources.ap_');
    final rJavaPath = p.join(ctx.buildDir, 'gen');

    final linkResult = await Process.run(
      aapt2,
      [
        'link',
        '-I',
        androidJar,
        '--manifest',
        manifestPath,
        '-o',
        linkedResPath,
        '--java',
        rJavaPath,
        '--auto-add-overlay',
        '-A',
        compiledResDir,
      ],
    );

    if (linkResult.exitCode != 0) {
      throw Exception('aapt2 link failed: ${linkResult.stderr}');
    }

    if (_verbose) {
      print('Resources compiled and linked successfully');
    }
  }

  /// Compile Kotlin and Java sources
  Future<void> compileKotlin(BuildContext ctx) async {
    final javac = await _sdkLocator.findJavac();
    final kotlinc = await _sdkLocator.findKotlinc();

    final srcDir =
        p.join(ctx.projectPath, 'android', 'app', 'src', 'main', 'java');
    final kotlinSrcDir =
        p.join(ctx.projectPath, 'android', 'app', 'src', 'main', 'kotlin');
    final genDir = p.join(ctx.buildDir, 'gen');
    final classesDir = p.join(ctx.buildDir, 'classes');
    await Directory(classesDir).create(recursive: true);

    // Find all Java and Kotlin source files
    final javaFiles = await _findSourceFiles(srcDir, '.java');
    final kotlinFiles = await _findSourceFiles(kotlinSrcDir, '.kt');
    final genJavaFiles = await _findSourceFiles(genDir, '.java');

    if (javaFiles.isEmpty && kotlinFiles.isEmpty && genJavaFiles.isEmpty) {
      if (_verbose) {
        print('No source files found to compile');
      }
      return;
    }

    // Get Android SDK jar
    final androidSdk = await _sdkLocator.findAndroidSdk();
    final androidJar = p.join(
      androidSdk,
      'platforms',
      'android-${ctx.config.android.compileSdk}',
      'android.jar',
    );

    // Compile Kotlin files first if kotlinc is available
    if (kotlinc != null && kotlinFiles.isNotEmpty) {
      final kotlinResult = await Process.run(
        kotlinc,
        [
          '-classpath',
          androidJar,
          '-d',
          classesDir,
          ...kotlinFiles,
        ],
      );

      if (kotlinResult.exitCode != 0) {
        throw Exception('kotlinc failed: ${kotlinResult.stderr}');
      }

      if (_verbose) {
        print('Kotlin compilation successful');
      }
    }

    // Compile Java files
    if (javaFiles.isNotEmpty || genJavaFiles.isNotEmpty) {
      final allJavaFiles = [...javaFiles, ...genJavaFiles];

      final javaResult = await Process.run(
        javac,
        [
          '-classpath',
          '$androidJar:$classesDir',
          '-d',
          classesDir,
          '-source',
          '1.8',
          '-target',
          '1.8',
          ...allJavaFiles,
        ],
      );

      if (javaResult.exitCode != 0) {
        throw Exception('javac failed: ${javaResult.stderr}');
      }

      if (_verbose) {
        print('Java compilation successful');
      }
    }
  }

  /// Convert compiled classes to DEX format
  Future<void> convertToDex(BuildContext ctx) async {
    final classesDir = p.join(ctx.buildDir, 'classes');
    final dexFile = p.join(ctx.buildDir, 'classes.dex');

    if (ctx.mode.isRelease) {
      // Try to use R8 for release builds with optimization
      final r8 = await _sdkLocator.findR8();

      if (r8 != null) {
        // Use R8 for optimized release builds
        final androidSdk = await _sdkLocator.findAndroidSdk();
        final androidJar = p.join(
          androidSdk,
          'platforms',
          'android-${ctx.config.android.compileSdk}',
          'android.jar',
        );

        final r8Result = await Process.run(
          'java',
          [
            '-cp',
            r8,
            'com.android.tools.r8.R8',
            '--release',
            '--lib',
            androidJar,
            '--output',
            p.dirname(dexFile),
            '--min-api',
            ctx.config.android.minSdk,
            classesDir,
          ],
        );

        if (r8Result.exitCode != 0) {
          throw Exception('R8 failed: ${r8Result.stderr}');
        }
      } else {
        // Fallback to D8 if R8 is not available
        print('⚠️  R8 not found, falling back to D8 (no optimization)');
        print('💡 Run "oka get r8" to install R8 for optimized builds');

        final d8 = await _sdkLocator.findD8();

        final d8Result = await Process.run(
          d8,
          [
            '--output',
            p.dirname(dexFile),
            '--min-api',
            ctx.config.android.minSdk,
            classesDir,
          ],
        );

        if (d8Result.exitCode != 0) {
          throw Exception('D8 failed: ${d8Result.stderr}');
        }
      }
    } else {
      // Use D8 for debug builds (faster, no optimization)
      final d8 = await _sdkLocator.findD8();

      final d8Result = await Process.run(
        d8,
        [
          '--output',
          p.dirname(dexFile),
          '--min-api',
          ctx.config.android.minSdk,
          classesDir,
        ],
      );

      if (d8Result.exitCode != 0) {
        throw Exception('D8 failed: ${d8Result.stderr}');
      }
    }

    if (_verbose) {
      print('DEX conversion successful');
    }
  }

  /// Package APK with all resources and DEX files
  Future<void> packageApk(BuildContext ctx) async {
    final apkPath = p.join(ctx.buildDir, 'app-${ctx.mode.name}-unsigned.apk');
    final resourcesApk = p.join(ctx.buildDir, 'resources.ap_');
    final dexFile = p.join(ctx.buildDir, 'classes.dex');

    // Copy resources APK as base
    await File(resourcesApk).copy(apkPath);

    // Add DEX file to APK using zip
    final zipResult = await Process.run(
      'zip',
      ['-j', apkPath, dexFile],
      workingDirectory: ctx.buildDir,
    );

    if (zipResult.exitCode != 0) {
      throw Exception('Failed to add DEX to APK: ${zipResult.stderr}');
    }

    if (_verbose) {
      print('APK packaged successfully');
    }
  }

  /// Sign APK with debug or release keystore
  Future<void> signApk(BuildContext ctx) async {
    final zipalign = await _sdkLocator.findZipalign();
    final apksigner = await _sdkLocator.findApksigner();

    final unsignedApk =
        p.join(ctx.buildDir, 'app-${ctx.mode.name}-unsigned.apk');
    final alignedApk = p.join(ctx.buildDir, 'app-${ctx.mode.name}-aligned.apk');
    final signedApk = p.join(ctx.buildDir, 'app-${ctx.mode.name}.apk');

    // Zipalign
    final zipalignResult = await Process.run(
      zipalign,
      ['-f', '4', unsignedApk, alignedApk],
    );

    if (zipalignResult.exitCode != 0) {
      throw Exception('zipalign failed: ${zipalignResult.stderr}');
    }

    // Sign
    // For now, use debug keystore (will implement release signing later)
    final debugKeystore = await _getDebugKeystore();

    final signResult = await Process.run(
      apksigner,
      [
        'sign',
        '--ks',
        debugKeystore,
        '--ks-pass',
        'pass:android',
        '--out',
        signedApk,
        alignedApk,
      ],
    );

    if (signResult.exitCode != 0) {
      throw Exception('apksigner failed: ${signResult.stderr}');
    }

    if (_verbose) {
      print('APK signed successfully');
    }
  }

  // Private helper methods

  Future<void> _createBuildDirectories(BuildContext ctx) async {
    final dirs = [
      ctx.buildDir,
      p.join(ctx.buildDir, 'compiled_res'),
      p.join(ctx.buildDir, 'gen'),
      p.join(ctx.buildDir, 'classes'),
    ];

    for (final dir in dirs) {
      await Directory(dir).create(recursive: true);
    }
  }

  Future<List<String>> _findSourceFiles(String dir, String extension) async {
    final directory = Directory(dir);
    if (!await directory.exists()) {
      return [];
    }

    final files = <String>[];
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File && entity.path.endsWith(extension)) {
        files.add(entity.path);
      }
    }

    return files;
  }

  Future<String> _getDebugKeystore() async {
    final home = Platform.environment['HOME'] ?? '';
    final debugKeystore = p.join(home, '.android', 'debug.keystore');

    if (await File(debugKeystore).exists()) {
      return debugKeystore;
    }

    // Generate debug keystore if it doesn't exist
    final androidDir = p.join(home, '.android');
    await Directory(androidDir).create(recursive: true);

    final keytoolResult = await Process.run(
      'keytool',
      [
        '-genkey',
        '-v',
        '-keystore',
        debugKeystore,
        '-storepass',
        'android',
        '-alias',
        'androiddebugkey',
        '-keypass',
        'android',
        '-keyalg',
        'RSA',
        '-keysize',
        '2048',
        '-validity',
        '10000',
        '-dname',
        'CN=Android Debug,O=Android,C=US',
      ],
    );

    if (keytoolResult.exitCode != 0) {
      throw Exception(
          'Failed to generate debug keystore: ${keytoolResult.stderr}');
    }

    return debugKeystore;
  }
}
