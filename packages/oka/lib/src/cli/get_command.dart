import 'dart:io';

import 'package:oka_android/oka_android.dart';

/// `oka get <noun>` — generic provisioning verb (ADR-0015: parse-and-delegate
/// shim; the Android provisioning mechanics + guidance strings live in
/// oka_android's provisioners, ADR-0013/T1 tool providers).
class GetCommand {
  /// Run the get command
  Future<void> run(List<String> args) async {
    if (args.isEmpty) {
      print(okaGetUsageText);
      return;
    }

    final target = args[0].toLowerCase();

    // Android nouns resolve through oka_android provisioners (ADR-0013/T1
    // tool-provider shape; ADR-0015: no platform dispatch literals here).
    final provisioner = androidProvisioners[target];

    switch (target) {
      case 'android-sdk':
      case 'packaging-sdk':
      case 'sdk':
        await _installAndroidSdk();
      case 'all':
        await _installAndroidSdk();
        await provisionAllMissingTools();
      case 'java':
        if (args.length < 2) {
          print('❌ Please specify Java version');
          print('   Example: oka get java 21');
          exit(1);
        }
        await _installJava(args[1]);
      case 'dep':
      case 'dependency':
        if (args.length < 2) {
          print('❌ Please specify a Maven coordinate');
          print('   Example: oka get dep androidx.window:window:1.3.0');
          exit(1);
        }
        await _installDependency(args[1]);
      default:
        if (provisioner == null) {
          print('❌ Unknown dependency: $target');
          print(okaGetUsageText);
          exit(1);
        }
        await provisioner();
    }
  }

  /// Download a single Maven coordinate into the oka cache and print the
  /// oka.yaml snippet (ADR-0002 dependency recovery).
  Future<void> _installDependency(String coordinate) async {
    final coord = MavenCoordinate.parse(coordinate);
    if (coord == null) {
      print(
        '❌ Invalid coordinate "$coordinate" — expected group:artifact:version',
      );
      exit(1);
    }
    print('📦 Resolving $coordinate...\n');
    try {
      final cache = DependencyCache(verbose: true);
      final jar = await cache.resolve(coord);
      print('✅ Cached: ${jar.jarPath}');
      print('');
      print('💡 Add to oka.yaml to include it in builds:');
      print('');
      print('pipeline:');
      print('  extra_deps:');
      print('    - "$coordinate"');
      print('');
      print('Then run: oka build apk');
    } catch (e) {
      print('❌ Failed to resolve $coordinate: $e');
      exit(1);
    }
  }

  Future<void> _installAndroidSdk() async {
    print('📦 Installing oka-managed packaging Android SDK...\n');
    final installer = AndroidSdkInstaller(verbose: true);
    print('   Root: ${installer.sdkRoot}');
    final result = await installer.installPackagingSdk();
    if (result.success) {
      print('✅ ${result.message}');
      print('   Packages: ${result.packages.join(', ')}');
      print('');
      print('💡 Export for this shell (optional):');
      print('   export OKA_ANDROID_SDK=${result.sdkRoot}');
      print('   export ANDROID_SDK_ROOT=${result.sdkRoot}');
      print('   Run: oka doctor');
    } else {
      print('❌ ${result.message}');
      exit(1);
    }
  }

  /// Install specific Java version
  Future<void> _installJava(String version) async {
    print('📦 Installing Java $version...\n');

    // Detect available version manager
    final versionManager = await VersionManager.detectBestVersionManager();

    if (versionManager == null) {
      print('❌ No version manager detected');
      print('');
      _printJavaInstallInstructions(version);
      exit(1);
    }

    print('🔍 Using ${versionManager.name} for installation...');
    print('');

    try {
      // Check if already installed
      final installedVersions = await versionManager
          .listInstalledJavaVersions();
      final alreadyInstalled = installedVersions.any(
        (v) =>
            v == version ||
            v.startsWith('$version.') ||
            v.startsWith('$version-'),
      );

      if (alreadyInstalled) {
        print('✅ Java $version is already installed');
        print('');
        print('💡 Run "oka doctor" to verify installation');
        return;
      }

      // Install
      final success = await versionManager.installJavaVersion(version);

      if (success) {
        print('');
        print('✅ Java $version installed successfully!');
        print('');
        print('💡 Run "oka doctor" to verify installation');
      } else {
        print('');
        print('❌ Failed to install Java $version');
        _printJavaInstallInstructions(version);
        exit(1);
      }
    } catch (e) {
      print('❌ Error: $e');
      _printJavaInstallInstructions(version);
      exit(1);
    }
  }

  /// Print Java installation instructions
  void _printJavaInstallInstructions(String version) {
    print('');
    print('═══════════════════════════════════════════════════════════');
    print('📋 Manual Java Installation Instructions');
    print('═══════════════════════════════════════════════════════════');
    print('');

    if (Platform.isLinux || Platform.isMacOS) {
      print('Option 1: Install SDKMAN! (recommended)');
      print('  curl -s "https://get.sdkman.io" | bash');
      print('  sdk install java $version-tem');
      print('');
      print('Option 2: Install asdf');
      print('  https://asdf-vm.com/guide/getting-started.html');
      print('  asdf plugin-add java');
      print('  asdf install java temurin-$version');
      print('');
    }

    if (Platform.isWindows) {
      print('Option 1: Use winget');
      print('  winget install EclipseAdoptium.Temurin.$version.JDK');
      print('');
    }

    if (Platform.isMacOS) {
      print('Option 3: Use Homebrew');
      print('  brew install openjdk@$version');
      print('');
    }

    print('Or download directly from:');
    print('  https://adoptium.net/');
    print('═══════════════════════════════════════════════════════════');
    print('');
  }
}
