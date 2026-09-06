import 'dart:io';
import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import 'sdk_locator.dart';

/// Android APK builder that orchestrates the build pipeline
class AndroidBuilder {

  AndroidBuilder(this._sdkLocator, {this._verbose = false});
  final SdkLocator _sdkLocator;
  final bool _verbose;

  /// Build APK from build context
  Future<BuildArtifact> buildApk(final BuildContext ctx) async {
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
  Future<void> compileResources(final BuildContext ctx) async {
    final aapt2 = await _sdkLocator.findAapt2();
    final androidSdk = await _sdkLocator.findAndroidSdk();

    final resDir =
        p.join(ctx.projectPath, 'android', 'app', 'src', 'main', 'res');
    // aapt2 compile --dir writes a compiled-resources ZIP (not a directory).
    final compiledResZip = p.join(ctx.buildDir, 'compiled_resources.zip');
    await Directory(ctx.buildDir).create(recursive: true);
    if (await File(compiledResZip).exists()) {
      await File(compiledResZip).delete();
    }

    final compileResult = await Process.run(
      aapt2,
      [
        'compile',
        '--dir',
        resDir,
        '-o',
        compiledResZip,
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
    await Directory(rJavaPath).create(recursive: true);

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
        '-R',
        compiledResZip,
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
  Future<void> compileKotlin(final BuildContext ctx) async {
    // Resolve Java environment first
    final javaEnvironment = await _sdkLocator.resolveJavaForKotlin(ctx);
    final env = javaEnvironment ?? Platform.environment;

    if (javaEnvironment != null && _verbose) {
      print('🔧 Using custom Java environment for Kotlin compilation');
      print('   JAVA_HOME: ${javaEnvironment['JAVA_HOME']}');
    }

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
    final androidxLifecycleJar = await _sdkLocator.findAndroidXLifecycle();
    final androidxLifecycleRuntimeJar =
        await _sdkLocator.findAndroidXLifecycleRuntime();

    // Build classpath with all required JARs
    final classpathSeparator = Platform.isWindows ? ';' : ':';
    final classpath = [
      androidJar,
      flutterJar,
      androidxAnnotationJar,
      androidxLifecycleJar,
      androidxLifecycleRuntimeJar,
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

      // Get the target Java version from config
      final targetJavaVersion = ctx.config.android.javaVersion;

      // Build JVM arguments list
      final jvmArgs = <String>[
        '-J-Dkotlin.incremental=false',
        '-J--add-opens=java.base/java.lang=ALL-UNNAMED',
        '-J--add-opens=java.base/java.lang.reflect=ALL-UNNAMED',
      ];

      final String kotlinCommand = kotlinc;

      final kotlinResult = await Process.run(
        kotlinCommand,
        [
          ...jvmArgs,
          '-classpath',
          kotlinClasspath,
          '-d',
          classesDir,
          '-jvm-target',
          '$targetJavaVersion',
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
        environment: env,
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
  Future<void> convertToDex(final BuildContext ctx) async {
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

    // Collect all dependency JARs that need to be included in DEX
    // These are the same JARs used during compilation
    final flutterJar = await _sdkLocator.findFlutterJar();
    final androidxAnnotationJar = await _sdkLocator.findAndroidXAnnotations();
    final androidxLifecycleJar = await _sdkLocator.findAndroidXLifecycle();
    final androidxLifecycleRuntimeJar =
        await _sdkLocator.findAndroidXLifecycleRuntime();
    final kotlinStdlib = await _sdkLocator.findKotlinStdlib();

    // Build list of all JARs to include in DEX
    final inputJars = [
      classesJar,
      flutterJar,
      androidxAnnotationJar,
      androidxLifecycleJar,
      androidxLifecycleRuntimeJar,
      ?kotlinStdlib,
    ];

    if (_verbose) {
      print('Including ${inputJars.length} JARs in DEX conversion:');
      for (final jar in inputJars) {
        print('  - ${p.basename(jar)}');
      }
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
            ...inputJars,
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
            ...inputJars,
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
          ...inputJars,
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
  Future<void> packageApk(final BuildContext ctx) async {
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
  Future<void> signApk(final BuildContext ctx) async {
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

  Future<void> _createBuildDirectories(final BuildContext ctx) async {
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

  Future<List<String>> _findSourceFiles(final String dir, final String extension) async {
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
