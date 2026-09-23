/// R8 shrinker provisioning (ADR-0007 self-resolving builds + ADR-0013
/// artifact store).
///
/// R8 is **not** part of the Android build-tools package: Google distributes
/// it via Maven (`com.android.tools:r8`), bundled inside AGP's
/// `builder.jar`. The Google Maven artifact's manifest points at
/// `com.android.tools.r8.SwissArmyKnife`, which the published `r8.jar` does
/// not contain — so the only reliable invocation is
/// `java -cp r8.jar com.android.tools.r8.R8` (verified against R8 9.4.24).
library;

import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Default keep rules oka feeds R8 for every release build (merged with the
/// project's `android.proguard_files`). Validated against R8 9.4.24.
const defaultR8KeepRules = '''
# Keep annotation/reflection metadata required by Flutter, Kotlin and
# serialization plugins.
-keepattributes Signature,InnerClasses,EnclosingMethod,AnnotationDefault,Exceptions
-keepattributes RuntimeVisibleAnnotations,RuntimeVisibleParameterAnnotations,AnnotationDefault

# Flutter embedding + generated plugin registrant (reflection entry points).
-keep class io.flutter.** { *; }
-keep class **PluginRegistrant { *; }

# Android manifest components (instantiated by name via reflection).
-keep class * extends android.app.Activity { *; }
-keep class * extends android.app.Application { *; }
-keep class * extends android.app.Service { *; }
-keep class * extends android.content.BroadcastReceiver { *; }
-keep class * extends android.content.ContentProvider { *; }

# JNI: native method names must survive obfuscation.
-keepclasseswithmembernames class * { native <methods>; }

# Parcelable CREATOR fields are resolved via reflection by the OS.
-keepclassmembers class * implements android.os.Parcelable {
  public static final ** CREATOR;
}

# Enum values()/valueOf() are called reflectively.
-keepclassmembers enum * {
  public static **[] values();
  public static ** valueOf(java.lang.String);
}
''';

/// R8 version provisioned by oka (stable Google Maven release).
const kR8Version = '9.4.24';

/// Google Maven download URL for the standalone R8 jar.
String r8MavenDownloadUrl({final String version = kR8Version}) =>
    'https://dl.google.com/android/maven2/'
    'com/android/tools/r8/$version/r8-$version.jar';

/// oka-managed R8 install directory: `~/.oka/tools/r8`.
String okaR8ToolsDir() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  return p.join(home, '.oka', 'tools', 'r8');
}

/// Default jar path for [version] under the oka tools directory.
String defaultR8JarPath({final String version = kR8Version}) =>
    p.join(okaR8ToolsDir(), 'r8-$version.jar');

/// Java command launching the R8 CLI from [r8Path].
///
/// A `.jar` must be run with `-cp <jar> com.android.tools.r8.R8` —
/// `java -jar` fails because the Maven artifact's manifest Main-Class
/// (`SwissArmyKnife`) is absent from the published jar. A non-jar path is
/// an `r8` wrapper binary.
List<String> r8Command(final String r8Path, final List<String> args) =>
    r8Path.toLowerCase().endsWith('.jar')
    ? ['java', '-cp', r8Path, 'com.android.tools.r8.R8', ...args]
    : [r8Path, ...args];

/// Locate an R8 jar: explicit path → `OKA_R8_JAR` → the oka tools directory
/// (`r8-<version>.jar`, then `r8.jar`). Returns the path or null.
///
/// [environment]/[home] are injectable so the toolchain policy can resolve
/// against a test environment instead of the host's real state.
Future<String?> findR8Jar({
  final String? explicitPath,
  final Map<String, String>? environment,
  final String? home,
}) async {
  final env = environment ?? Platform.environment;
  final homeDir = home ?? env['HOME'] ?? env['USERPROFILE'] ?? '';
  final candidates = [
    if (explicitPath != null && explicitPath.isNotEmpty) explicitPath,
    env['OKA_R8_JAR'],
    if (homeDir.isNotEmpty)
      p.join(homeDir, '.oka', 'tools', 'r8', 'r8-$kR8Version.jar'),
    if (homeDir.isNotEmpty) p.join(homeDir, '.oka', 'tools', 'r8', 'r8.jar'),
  ].whereType<String>().toList();
  for (final c in candidates) {
    if (await File(c).exists()) return c;
  }
  return null;
}

/// Download R8 [version] into the oka tools directory through the shared
/// artifact store (ADR-0013: `oka cache list/gc` sees it; OKA_CACHE shares
/// it). Returns the installed jar path.
Future<String> installR8({
  final String version = kR8Version,
  final bool verbose = false,
}) async {
  final url = r8MavenDownloadUrl(version: version);
  final store = LocalArtifactStore();
  final jar = await store.fetch(
    ContentKey.compute(
      category: 'r8',
      name: 'r8',
      version: version,
      inputs: [url],
    ),
    () async {
      final tmp = await Directory.systemTemp.createTemp('oka_r8_');
      final tempFile = p.join(tmp.path, 'r8-$version.jar');
      final download = await Process.run('curl', [
        '-L',
        '-f',
        '-o',
        tempFile,
        url,
      ], runInShell: true);
      if (download.exitCode != 0) {
        throw Exception(
          'Failed to download R8 $version from $url: ${download.stderr}',
        );
      }
      return File(tempFile);
    },
  );

  final toolsDir = okaR8ToolsDir();
  await Directory(toolsDir).create(recursive: true);
  final dest = p.join(toolsDir, 'r8-$version.jar');
  if (p.normalize(jar.path) != p.normalize(dest)) {
    await File(jar.path).copy(dest);
  }
  if (verbose) print('📥 R8 $version installed → $dest');
  return dest;
}
