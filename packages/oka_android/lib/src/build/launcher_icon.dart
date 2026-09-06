import 'dart:io';

import 'package:path/path.dart' as p;

/// Launcher icon configuration (ADR-0002 fast-settings).
///
/// ```yaml
/// android:
///   icon:
///     background_color: "#4CAF50"   # adaptive-icon background (color)
///     vector: assets/icon/fg.xml    # optional custom VectorDrawable foreground
///     monochrome: assets/icon/mono.xml  # optional Android 13+ themed icon
/// ```
class IconConfig {

  const IconConfig({
    this.backgroundColor = '#FFFFFF',
    this.vector = '',
    this.monochrome = '',
  });
  /// Background as a color literal (`#RRGGBB` / `#AARRGGBB`) or resource ref.
  final String backgroundColor;

  /// Project-relative path to a custom VectorDrawable XML used as the
  /// adaptive-icon foreground. When empty, oka generates a default glyph.
  final String vector;

  /// Optional project-relative path to a monochrome VectorDrawable
  /// (Android 13+ themed icons).
  final String monochrome;

  factory IconConfig.fromMap(final Map<dynamic, dynamic> map) => IconConfig(
      backgroundColor: map['background_color']?.toString() ?? '#FFFFFF',
      vector: map['vector']?.toString() ?? '',
      monochrome: map['monochrome']?.toString() ?? '',
    );
}

/// Result of staging launcher icon resources.
class IconResources {

  const IconResources({required this.written, required this.manifestRef});
  /// res-relative paths written (e.g. `mipmap-anydpi-v26/ic_launcher.xml`).
  final List<String> written;

  /// `android:icon` resource reference for the manifest.
  final String manifestRef;
}

/// Generates adaptive launcher icon resources (vector-first, no binary deps).
///
/// Strategy:
/// - Always writes `mipmap-anydpi-v26/ic_launcher.xml` (adaptive icon) plus a
///   foreground drawable and background color resource. Works on API 26+
///   with pure XML — no PNG tooling required.
/// - Optionally uses user-supplied VectorDrawable XML for the foreground and
///   monochrome layer instead of the generated glyph.
Future<IconResources> stageLauncherIcons(
  final String resDir,
  final IconConfig config, {
  required final String projectPath,
}) async {
  final written = <String>[];

  // Foreground drawable: user-supplied vector or oka default glyph.
  final fgResDir = p.join(resDir, 'drawable');
  await Directory(fgResDir).create(recursive: true);
  if (config.vector.isNotEmpty) {
    final src = File(p.join(projectPath, config.vector));
    if (!await src.exists()) {
      throw Exception('icon.vector not found: ${config.vector}');
    }
    await src.copy(p.join(fgResDir, 'ic_launcher_foreground.xml'));
  } else {
    await File(
      p.join(fgResDir, 'ic_launcher_foreground.xml'),
    ).writeAsString(defaultForegroundVector());
  }
  written.add('drawable/ic_launcher_foreground.xml');

  // Monochrome layer (Android 13+ themed icons), optional.
  var monoRef = '';
  if (config.monochrome.isNotEmpty) {
    final src = File(p.join(projectPath, config.monochrome));
    if (!await src.exists()) {
      throw Exception('icon.monochrome not found: ${config.monochrome}');
    }
    await src.copy(p.join(fgResDir, 'ic_launcher_monochrome.xml'));
    monoRef = '@drawable/ic_launcher_monochrome';
    written.add('drawable/ic_launcher_monochrome.xml');
  }

  // Background color resource.
  final valuesDir = p.join(resDir, 'values');
  await Directory(valuesDir).create(recursive: true);
  await File(p.join(valuesDir, 'ic_launcher_background.xml')).writeAsString(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources>\n'
    '    <color name="ic_launcher_background">${_escapeColor(config.backgroundColor)}</color>\n'
    '</resources>\n',
  );
  written.add('values/ic_launcher_background.xml');

  // Adaptive icon definition (API 26+; minSdk of modern Flutter apps).
  final anyDpiDir = p.join(resDir, 'mipmap-anydpi-v26');
  await Directory(anyDpiDir).create(recursive: true);
  final monoLine = monoRef.isEmpty
      ? ''
      : '\n    <monochrome android:drawable="$monoRef"/>';
  await File(p.join(anyDpiDir, 'ic_launcher.xml')).writeAsString(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@color/ic_launcher_background"/>'
    '${monoLine.isEmpty ? '' : monoLine}\n'
    '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
    '</adaptive-icon>\n',
  );
  written.add('mipmap-anydpi-v26/ic_launcher.xml');

  return IconResources(written: written, manifestRef: '@mipmap/ic_launcher');
}

/// Default oka glyph: rounded "O" ring centered in the adaptive-icon safe
/// zone (108dp viewport, content within inner ~66dp).
String defaultForegroundVector() => '''
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- Oka "O" ring -->
    <path
        android:fillColor="#00000000"
        android:strokeColor="#2E7D32"
        android:strokeWidth="9"
        android:pathData="M54,54 m-20,0 a20,20 0 1,1 40,0 a20,20 0 1,1 -40,0"/>
    <!-- Spark dot -->
    <path
        android:fillColor="#2E7D32"
        android:pathData="M70,38 m-5,0 a5,5 0 1,1 10,0 a5,5 0 1,1 -10,0"/>
</vector>
''';

/// Validates/normalizes a color literal; passes through resource refs (@...).
String _escapeColor(final String raw) {
  final v = raw.trim();
  if (v.startsWith('@')) return v;
  if (!RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(v)) {
    throw Exception(
      'icon.background_color must be #RRGGBB / #AARRGGBB or @resource ref, '
      'got "$raw"',
    );
  }
  return v;
}
