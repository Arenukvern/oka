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

    // Find all compiled resource files
    final compiledFiles = await _findSourceFiles(compiledResDir, '.flat');

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
        ...compiledFiles.expand((f) => ['-R', f]),
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

    // Get Flutter and AndroidX JARs
    final flutterJar = await _sdkLocator.findFlutterJar();
    final androidxAnnotationJar = await _sdkLocator.findAndroidXAnnotations();

    // Build classpath with all required JARs
    final classpathSeparator = Platform.isWindows ? ';' : ':';
    final classpath = [
      androidJar,
      flutterJar,
      androidxAnnotationJar,
      classesDir,
    ].join(classpathSeparator);

    // Compile Kotlin files first if kotlinc is available
    if (kotlinc != null && kotlinFiles.isNotEmpty) {
      // Get Kotlin standard library for compilation
      final kotlinStdlib = await _sdkLocator.findKotlinStdlib();

      // Build Kotlin-specific classpath with stdlib
      final kotlinClasspath = kotlinStdlib != null
          ? '$classpath$classpathSeparator$kotlinStdlib'
          : classpath;

      if (_verbose) {
        print('Compiling ${kotlinFiles.length} Kotlin file(s)...');
        if (kotlinStdlib != null) {
          print('Using Kotlin stdlib: $kotlinStdlib');
        }
      }

      // Add JVM arguments to handle newer Java versions
      // Set environment to work around Java version detection issues
      final env = Map<String, String>.from(Platform.environment);
      env['JAVA_OPTS'] = '-Dkotlin.incremental=false';

      final kotlinResult = await Process.run(
        kotlinc,
        [
          '-J-Djava.version=21',
          '-J-Dkotlin.incremental=false',
          '-classpath',
          kotlinClasspath,
          '-d',
          classesDir,
          '-jvm-target',
          '11',
          ...kotlinFiles,
        ],
        environment: env,
      );

      if (_verbose) {
        if (kotlinResult.stdout.toString().isNotEmpty) {
          print('kotlinc stdout: ${kotlinResult.stdout}');
        }
        if (kotlinResult.stderr.toString().isNotEmpty) {
          print('kotlinc stderr: ${kotlinResult.stderr}');
        }
      }

      if (kotlinResult.exitCode != 0) {
        print('❌ Kotlin compilation failed:');
        print(kotlinResult.stderr);
        if (kotlinResult.stdout.toString().isNotEmpty) {
          print(kotlinResult.stdout);
        }
        throw Exception(
            'kotlinc failed with exit code ${kotlinResult.exitCode}');
      }

      if (_verbose) {
        print('✓ Kotlin compilation successful');
      }
    } else if (kotlinFiles.isNotEmpty && kotlinc == null) {
      print('');
      print(
          '❌ Kotlin compiler not found but ${kotlinFiles.length} Kotlin file(s) need to be compiled');
      print('');
      print('📥 Auto-installing Kotlin compiler...');
      print('   Run "oka get kotlin" to install manually');
      print('');
      throw Exception('Kotlin compiler required. Run: oka get kotlin');
    }

    // Compile Java files
    if (javaFiles.isNotEmpty || genJavaFiles.isNotEmpty) {
      final allJavaFiles = [...javaFiles, ...genJavaFiles];

      if (_verbose) {
        print('Compiling ${allJavaFiles.length} Java file(s)...');
      }

      final javaResult = await Process.run(
        javac,
        [
          '-classpath',
          classpath,
          '-d',
          classesDir,
          '--release',
          '${ctx.config.android.javaVersion}',
          ...allJavaFiles,
        ],
      );

      if (_verbose) {
        if (javaResult.stdout.toString().isNotEmpty) {
          print('javac stdout: ${javaResult.stdout}');
        }
        if (javaResult.stderr.toString().isNotEmpty) {
          print('javac stderr: ${javaResult.stderr}');
        }
      }

      if (javaResult.exitCode != 0) {
        print('❌ Java compilation failed:');
        print(javaResult.stderr);
        if (javaResult.stdout.toString().isNotEmpty) {
          print(javaResult.stdout);
        }
        throw Exception('javac failed with exit code ${javaResult.exitCode}');
      }

      if (_verbose) {
        print('✓ Java compilation successful');
      }
    }
  }

  /// Convert compiled classes to DEX format
  Future<void> convertToDex(BuildContext ctx) async {
    final classesDir = p.join(ctx.buildDir, 'classes');
    final classesJar = p.join(ctx.buildDir, 'classes.jar');
    final dexFile = p.join(ctx.buildDir, 'classes.dex');

    // Create JAR from compiled classes
    // D8/R8 prefer JAR input over directory input
    final jarResult = await Process.run(
      'jar',
      ['cf', classesJar, '-C', classesDir, '.'],
    );

    if (jarResult.exitCode != 0) {
      throw Exception('Failed to create classes JAR: ${jarResult.stderr}');
    }

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
            classesJar,
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
            classesJar,
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
          classesJar,
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
