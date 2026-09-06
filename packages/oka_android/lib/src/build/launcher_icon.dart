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
///     name: my_launcher             # base resource name (default ic_launcher)
///     manifest_ref: "@mipmap/my_launcher"  # full override — generate nothing
/// ```
///
/// With `manifest_ref` set, oka generates no icon resources at all and uses
/// the reference verbatim — the icon resource must already exist in the
/// merged res tree (e.g. shipped via `res_dirs`) under any name you choose.
class IconConfig {
  const IconConfig({
    this.backgroundColor = '#FFFFFF',
    this.vector = '',
    this.monochrome = '',
    this.name = 'ic_launcher',
    this.manifestRef = '',
  });

  factory IconConfig.fromMap(final Map<dynamic, dynamic> map) => IconConfig(
      backgroundColor: map['background_color']?.toString() ?? '#FFFFFF',
      vector: map['vector']?.toString() ?? '',
      monochrome: map['monochrome']?.toString() ?? '',
      name: map['name']?.toString() ?? 'ic_launcher',
      manifestRef: map['manifest_ref']?.toString() ?? '',
    );

  /// Background as a color literal (`#RRGGBB` / `#AARRGGBB`) or resource ref.
  final String backgroundColor;

  /// Project-relative path to a custom VectorDrawable XML used as the
  /// adaptive-icon foreground. When empty, oka generates a default glyph.
  final String vector;

  /// Optional project-relative path to a monochrome VectorDrawable
  /// (Android 13+ themed icons).
  final String monochrome;

  /// Base resource name for generated icon resources: the adaptive icon at
  /// `mipmap-anydpi-v26/<name>.xml`, the foreground/background/monochrome
  /// companions, and the manifest reference `@mipmap/<name>`. Change it when
  /// your project already ships an icon under a different name.
  final String name;

  /// Full manifest icon reference (e.g. `@mipmap/my_launcher`). When set,
  /// oka generates nothing — the icon resource must already exist in the
  /// merged res tree (e.g. via `res_dirs`), under any name you choose.
  final String manifestRef;

  /// True when no icon fast-settings are configured (all defaults).
  bool get isDefault =>
      vector.isEmpty &&
      monochrome.isEmpty &&
      manifestRef.isEmpty &&
      name == 'ic_launcher' &&
      backgroundColor == '#FFFFFF';
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
  final name = config.name;

  // Foreground drawable: user-supplied vector or oka default glyph.
  final fgResDir = p.join(resDir, 'drawable');
  await Directory(fgResDir).create(recursive: true);
  if (config.vector.isNotEmpty) {
    final src = File(p.join(projectPath, config.vector));
    if (!await src.exists()) {
      throw Exception('icon.vector not found: ${config.vector}');
    }
    await src.copy(p.join(fgResDir, '${name}_foreground.xml'));
  } else {
    await File(
      p.join(fgResDir, '${name}_foreground.xml'),
    ).writeAsString(defaultForegroundVector());
  }
  written.add('drawable/${name}_foreground.xml');

  // Monochrome layer (Android 13+ themed icons), optional.
  var monoRef = '';
  if (config.monochrome.isNotEmpty) {
    final src = File(p.join(projectPath, config.monochrome));
    if (!await src.exists()) {
      throw Exception('icon.monochrome not found: ${config.monochrome}');
    }
    await src.copy(p.join(fgResDir, '${name}_monochrome.xml'));
    monoRef = '@drawable/${name}_monochrome';
    written.add('drawable/${name}_monochrome.xml');
  }

  // Background color resource.
  final valuesDir = p.join(resDir, 'values');
  await Directory(valuesDir).create(recursive: true);
  await File(p.join(valuesDir, '${name}_background.xml')).writeAsString(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources>\n'
    '    <color name="${name}_background">${_escapeColor(config.backgroundColor)}</color>\n'
    '</resources>\n',
  );
  written.add('values/${name}_background.xml');

  // Adaptive icon definition (API 26+; minSdk of modern Flutter apps).
  final anyDpiDir = p.join(resDir, 'mipmap-anydpi-v26');
  await Directory(anyDpiDir).create(recursive: true);
  final monoLine = monoRef.isEmpty
      ? ''
      : '\n    <monochrome android:drawable="$monoRef"/>';
  await File(p.join(anyDpiDir, '$name.xml')).writeAsString(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@color/${name}_background"/>'
    '${monoLine.isEmpty ? '' : monoLine}\n'
    '    <foreground android:drawable="@drawable/${name}_foreground"/>\n'
    '</adaptive-icon>\n',
  );
  written.add('mipmap-anydpi-v26/$name.xml');

  return IconResources(written: written, manifestRef: '@mipmap/$name');
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
