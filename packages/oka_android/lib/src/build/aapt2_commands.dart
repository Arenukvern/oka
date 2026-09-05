/// Pure aapt2 argv construction for the no-Gradle packaging path.
///
/// aapt2 rules used here:
/// - `compile --dir <resDir> -o <out.zip>` writes a **compiled-resources ZIP**
///   (not a directory of .flat files).
/// - `link ... -R <compiled.zip>` consumes that single ZIP (not per-file -R).

/// Args after the aapt2 executable for directory resource compilation.
List<String> buildAapt2CompileDirArgs({
  required String resDir,
  required String compiledResourcesZip,
}) {
  if (!compiledResourcesZip.endsWith('.zip') &&
      !compiledResourcesZip.endsWith('.flata')) {
    // Still allow non-.zip paths but prefer .zip; callers should pass a file path.
  }
  return <String>['compile', '--dir', resDir, '-o', compiledResourcesZip];
}

/// Args after the aapt2 executable for linking a compiled-resources zip.
List<String> buildAapt2LinkArgs({
  required String androidJar,
  required String manifestPath,
  required String outputAp,
  required String compiledResourcesZip,
  String? javaOutDir,
  String? assetsDir,
  bool autoAddOverlay = true,
  List<String> resourceConfigs = const [],
  String? versionCode,
  String? versionName,
}) {
  return <String>[
    'link',
    '-I',
    androidJar,
    '--manifest',
    manifestPath,
    '-o',
    outputAp,
    // Version from oka.yaml (gradle's flutter.versionCode/Name equivalent).
    if (versionCode != null && versionCode.isNotEmpty) ...[
      '--version-code',
      versionCode,
    ],
    if (versionName != null && versionName.isNotEmpty) ...[
      '--version-name',
      versionName,
    ],
    if (javaOutDir != null) ...['--java', javaOutDir],
    if (autoAddOverlay) '--auto-add-overlay',
    if (assetsDir != null) ...['-A', assetsDir],
    // resourceConfigurations (e.g. ['en','ru']) — keeps only matching
    // resource qualifiers in the output (size + store expectations).
    if (resourceConfigs.isNotEmpty) ...['-c', resourceConfigs.join(',')],
    // Single compiled-resources archive from `aapt2 compile --dir ... -o zip`
    '-R',
    compiledResourcesZip,
  ];
}

/// Args after aapt2 for linking in **proto format** (App Bundle inputs).
///
/// Produces `AndroidManifest.xml` (protobuf), `resources.pb` and compiled
/// `res/**` inside the output archive — the exact layout an AAB `base/`
/// module expects. Reuses the same single `-R <compiled.zip>` rule as
/// [buildAapt2LinkArgs].
List<String> buildAapt2LinkProtoFormatArgs({
  required String androidJar,
  required String manifestPath,
  required String outputAp,
  required String compiledResourcesZip,
  String? javaOutDir,
  bool autoAddOverlay = true,
  List<String> resourceConfigs = const [],
  String? versionCode,
  String? versionName,
}) {
  return <String>[
    'link',
    '--proto-format',
    '-I',
    androidJar,
    '--manifest',
    manifestPath,
    '-o',
    outputAp,
    if (javaOutDir != null) ...['--java', javaOutDir],
    if (autoAddOverlay) '--auto-add-overlay',
    if (versionCode != null && versionCode.isNotEmpty) ...[
      '--version-code',
      versionCode,
    ],
    if (versionName != null && versionName.isNotEmpty) ...[
      '--version-name',
      versionName,
    ],
    if (resourceConfigs.isNotEmpty) ...['-c', resourceConfigs.join(',')],
    '-R',
    compiledResourcesZip,
  ];
}

/// Returns true if [path] looks like a compiled-resources archive file path
/// (not a directory intended to hold loose .flat files).
bool isCompiledResourcesZipPath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.flata') ||
      lower.endsWith('.ap_');
}
