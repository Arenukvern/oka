import 'package:oka_core/oka_core.dart';

/// Pure ordered source and remediation policy for Android host tools.
final class AndroidToolPolicy {
  const AndroidToolPolicy({
    required this.hasConfiguredAndroidSdk,
    required this.hasConfiguredFlutterSdk,
  });

  final bool hasConfiguredAndroidSdk;
  final bool hasConfiguredFlutterSdk;

  static const buildTools = ['aapt2', 'd8', 'zipalign', 'apksigner'];

  List<ToolSource> get androidSdkSources => [
    if (hasConfiguredAndroidSdk)
      const ToolSource(ToolSourceKind.config, 'androidSdkPath'),
    const ToolSource(ToolSourceKind.env, 'OKA_ANDROID_SDK'),
    const ToolSource(ToolSourceKind.managed, '~/.oka/android-sdk'),
    const ToolSource(ToolSourceKind.env, 'ANDROID_HOME'),
    const ToolSource(ToolSourceKind.env, 'ANDROID_SDK_ROOT'),
    const ToolSource(ToolSourceKind.system, '~/Android/Sdk'),
    const ToolSource(ToolSourceKind.system, '~/Library/Android/sdk'),
    const ToolSource(ToolSourceKind.system, '/usr/local/android-sdk'),
  ];

  List<ToolSource> describe(String name) {
    if (name == 'android-sdk') return androidSdkSources;
    if (name == 'flutter-sdk') {
      return [
        if (hasConfiguredFlutterSdk)
          const ToolSource(ToolSourceKind.config, 'flutterSdkPath'),
        const ToolSource(ToolSourceKind.system, 'PATH (which flutter)'),
      ];
    }
    if (buildTools.contains(name)) {
      return [
        for (final source in androidSdkSources)
          ToolSource(
            source.kind,
            '${source.label} → build-tools/<latest>/$name',
          ),
      ];
    }
    if (name == 'r8') {
      return [
        for (final source in androidSdkSources)
          ToolSource(
            source.kind,
            '${source.label} → build-tools/<latest>/{r8,lib/r8.jar}',
          ),
        const ToolSource(
          ToolSourceKind.managed,
          'cmdline-tools/latest/lib/r8.jar',
        ),
      ];
    }
    final relative = switch (name) {
      'adb' => 'platform-tools/adb',
      'emulator' => 'emulator/emulator',
      'avdmanager' => 'cmdline-tools/latest/bin/avdmanager',
      'system-images' => 'system-images/',
      _ => null,
    };
    if (relative != null) {
      return [
        for (final source in androidSdkSources)
          ToolSource(source.kind, '${source.label} → $relative'),
      ];
    }
    return switch (name) {
      'kotlinc' => const [
        ToolSource(ToolSourceKind.managed, '~/.oka/tools/kotlin-*/bin'),
        ToolSource(ToolSourceKind.system, 'PATH (which kotlinc)'),
        ToolSource(ToolSourceKind.env, 'KOTLIN_HOME/bin'),
      ],
      'javac' => const [
        ToolSource(ToolSourceKind.system, 'PATH (which javac)'),
        ToolSource(ToolSourceKind.env, 'JAVA_HOME/bin'),
      ],
      'kotlin-stdlib' => const [
        ToolSource(
          ToolSourceKind.managed,
          '<kotlinc home>/lib/kotlin-stdlib*.jar',
        ),
      ],
      'flutter-jar' => const [
        ToolSource(
          ToolSourceKind.managed,
          '<flutter sdk>/bin/cache/artifacts/engine/{android-x64,android-arm,android-arm64,android}/flutter.jar',
        ),
      ],
      _ => const [],
    };
  }

  String remediation(String tool) => switch (tool) {
    'android-sdk' =>
      'Run `oka get android-sdk`, or set OKA_ANDROID_SDK / ANDROID_HOME / ANDROID_SDK_ROOT to an existing SDK.',
    'flutter-sdk' => 'Ensure Flutter is installed and in PATH.',
    'javac' => 'Install a JDK and set JAVA_HOME (e.g. `oka get jdk`).',
    'kotlinc' => 'Run `oka get kotlin`.',
    'flutter-jar' =>
      'Run `flutter precache --android` to download engine artifacts.',
    'adb' =>
      'Install platform-tools (`sdkmanager "platform-tools"`) or run `oka get android-sdk`.',
    'emulator' =>
      'Install the emulator (`sdkmanager "emulator"`) or run `oka get android-sdk`.',
    'avdmanager' =>
      'Install cmdline-tools (`sdkmanager "cmdline-tools;latest"`) or run `oka get android-sdk`.',
    'system-images' =>
      'Install a system image, e.g. `sdkmanager "system-images;android-34;google_apis;x86_64"`.',
    'r8' => 'Run `oka get r8` to install.',
    _ when buildTools.contains(tool) =>
      'Install build-tools (`sdkmanager "build-tools;34.0.0"`) or run `oka get android-sdk`.',
    _ => 'Run `oka doctor` for a full environment check.',
  };
}
