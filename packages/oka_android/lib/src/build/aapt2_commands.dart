/// Pure aapt2 argv construction for the no-Gradle packaging path.
///
/// aapt2 rules used here:
/// - `compile --dir <resDir> -o <out.zip>` writes a **compiled-resources ZIP**
///   (not a directory of .flat files).
/// - `link ... -R <compiled.zip>` consumes that single ZIP (not per-file -R).
library;

/// Args after the aapt2 executable for directory resource compilation.
List<String> buildAapt2CompileDirArgs({
  required final String resDir,
  required final String compiledResourcesZip,
}) {
  if (!compiledResourcesZip.endsWith('.zip') &&
      !compiledResourcesZip.endsWith('.flata')) {
    // Still allow non-.zip paths but prefer .zip; callers should pass a file path.
  }
  return <String>['compile', '--dir', resDir, '-o', compiledResourcesZip];
}

/// Args after the aapt2 executable for linking compiled-resources zips.
///
/// [compiledResourcesZip] is the primary (app) set; each entry of
/// [overlayZips] is a secondary (AAR/plugin) set. With
/// `--auto-add-overlay`, resources from every zip merge into the output and
/// same-named resources resolve to the LAST `-R` zip that defines them — so
/// the primary zip is emitted last and wins, matching Gradle's
/// app-over-library merge precedence.
List<String> buildAapt2LinkArgs({
  required final String androidJar,
  required final String manifestPath,
  required final String outputAp,
  required final String compiledResourcesZip,
  final List<String> overlayZips = const [],
  final String? javaOutDir,
  final String? assetsDir,
  final bool autoAddOverlay = true,
  final List<String> resourceConfigs = const [],
  final String? versionCode,
  final String? versionName,
}) => <String>[
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
  // Compiled-resources archives from `aapt2 compile --dir ... -o zip`;
  // later -R zips override same-named resources, primary comes last.
  for (final zip in overlayZips) ...['-R', zip],
  '-R',
  compiledResourcesZip,
];

/// Args after aapt2 for linking in **proto format** (App Bundle inputs).
///
/// Produces `AndroidManifest.xml` (protobuf), `resources.pb` and compiled
/// `res/**` inside the output archive — the exact layout an AAB `base/`
/// module expects. Same multi-zip overlay rule as [buildAapt2LinkArgs]:
/// [overlayZips] first, primary [compiledResourcesZip] last (wins).
List<String> buildAapt2LinkProtoFormatArgs({
  required final String androidJar,
  required final String manifestPath,
  required final String outputAp,
  required final String compiledResourcesZip,
  final List<String> overlayZips = const [],
  final String? javaOutDir,
  final bool autoAddOverlay = true,
  final List<String> resourceConfigs = const [],
  final String? versionCode,
  final String? versionName,
}) => <String>[
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
  for (final zip in overlayZips) ...['-R', zip],
  '-R',
  compiledResourcesZip,
];

/// Returns true if [path] looks like a compiled-resources archive file path
/// (not a directory intended to hold loose .flat files).
bool isCompiledResourcesZipPath(final String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.flata') ||
      lower.endsWith('.ap_');
}
