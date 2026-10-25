import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'manifest_placeholders.dart';

/// Merges library manifest declarations into the app manifest.
///
/// aapt2 links only the manifest it is handed — Gradle's manifest merger
/// normally folds every AAR's component declarations into the app manifest.
/// Without this fold, libraries that declare runtime components crash at
/// initialization: CameraX, for example, fails with
/// `NameNotFoundException: androidx.camera.core.impl.MetadataHolderService`
/// because its `<service>` never reached the APK manifest.
///
/// Merge rules (mirroring the Gradle merger for the common cases):
/// - Under `<manifest>`: `uses-permission`, `uses-permission-sdk-23`, and
///   `uses-feature` are copied when no element with the same tag and
///   `android:name` (or attribute signature) exists yet.
/// - Under `<application>`: `activity`, `activity-alias`, `service`,
///   `receiver`, `provider`, `meta-data`, and `uses-library` are copied
///   under the same rule.
/// - Elements marked `tools:node="remove"` are skipped.
/// - The app manifest's own elements are never modified or removed.
///
/// Manifest placeholders are resolved the way Gradle resolves them before
/// the fold: `${applicationId}` becomes the app's install-time package (the
/// app manifest's `package` attribute — aapt2 links the manifest as it is,
/// and oka never renames the package at link time). An element that still
/// carries an unresolved placeholder is skipped and named on stderr: a
/// literal `${…}` in a manifest breaks at install time, so it is never
/// merged as if it were resolved.
///
/// Returns the number of elements added.
int mergeLibraryManifestsInto({
  required String appManifestPath,
  required Iterable<String> libraryManifestPaths,
  String? applicationId,
}) {
  final appFile = File(appManifestPath);
  final appDocument = XmlDocument.parse(appFile.readAsStringSync());
  final appRoot = appDocument.rootElement;
  if (appRoot.name.local != 'manifest') {
    throw ArgumentError(
      '${p.relative(appManifestPath)}: root element is '
      '<${appRoot.name.local}>, expected <manifest>',
    );
  }
  final application = appRoot.findElements('application').firstOrNull;
  if (application == null) {
    throw ArgumentError(
      '${p.relative(appManifestPath)}: no <application> element',
    );
  }

  final additions = <(XmlElement, XmlElement)>[];

  // Dedupe bookkeeping for this invocation: per target element, the set of
  // merge keys already seen for each tag.
  final seenKeys = <XmlElement, Map<String, Set<String>>>{};

  // The app manifest's `package` attribute is the app's install-time
  // package: it is what aapt2 links, and oka never renames the package at
  // link time. An explicit application id wins over it.
  final resolvedApplicationId =
      applicationId ?? appRoot.getAttribute('package');
  final placeholders =
      resolvedApplicationId == null || resolvedApplicationId.isEmpty
          ? null
          : ManifestPlaceholders(applicationId: resolvedApplicationId);

  void mergeInto(
    XmlElement target,
    Iterable<String> tags,
    XmlDocument library,
  ) {
    final seenForTarget = seenKeys.putIfAbsent(target, () => {});
    for (final tag in tags) {
      final existing = seenForTarget.putIfAbsent(
        tag,
        () => {
          for (final e in target.findElements(tag)) elementMergeKey(e),
        },
      );
      // Library manifests nest components under <application>, so search
      // all descendants; app-manifest dedupe reads direct children only.
      for (final element in library.rootElement.findAllElements(tag)) {
        if (element.getAttribute('node', namespaceUri: toolsNamespaceUri) ==
            'remove') {
          continue;
        }
        // Gradle would substitute manifest placeholders (${applicationId});
        // aapt2 cannot, and a literal placeholder breaks at install time.
        // Substitute what the build knows, then refuse what is left. The
        // merge key is taken from the substituted element, so a library
        // placeholder and the app's own literal declaration are the same
        // declaration.
        final copy = element.copy();
        placeholders?.substituteInto(copy);
        final unresolved = ManifestPlaceholders.unresolvedInElement(copy);
        if (unresolved.isNotEmpty) {
          final name =
              copy.getAttribute('name', namespaceUri: androidNamespaceUri);
          stderr.writeln(
            'oka: manifest merge skipped ${element.name.qualified}'
            '${name == null ? '' : ' ($name)'} — unresolved manifest '
            'placeholder(s): ${unresolved.join(', ')}',
          );
          continue;
        }
        final key = elementMergeKey(copy);
        if (existing.contains(key)) continue;
        existing.add(key);
        additions.add((target, _stripToolsAttributes(copy)));
      }
    }
  }

  for (final path in libraryManifestPaths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final XmlDocument library;
    try {
      library = XmlDocument.parse(file.readAsStringSync());
    } on XmlException catch (error) {
      stderr.writeln(
        'oka: manifest merge skipped for ${p.relative(path)}: '
        'unparsable XML ($error)',
      );
      continue;
    }
    if (library.rootElement.name.local != 'manifest') continue;
    mergeInto(appRoot, manifestChildTags, library);
    final libApplication =
        library.rootElement.findElements('application').firstOrNull;
    if (libApplication == null) continue;
    mergeInto(application, applicationChildTags, library);
  }

  void addPair((XmlElement, XmlElement) pair) =>
      pair.$1.children.add(pair.$2);
  additions.forEach(addPair);
  if (additions.isNotEmpty) {
    appFile.writeAsStringSync(
      appDocument.toXmlString(pretty: true, indent: '    '),
    );
  }
  return additions.length;
}

const androidNamespaceUri = 'http://schemas.android.com/apk/res/android';
const toolsNamespaceUri = 'http://schemas.android.com/apk/res/tools';

const manifestChildTags = <String>[
  'uses-permission',
  'uses-permission-sdk-23',
  'uses-feature',
];

const applicationChildTags = <String>[
  'activity',
  'activity-alias',
  'service',
  'receiver',
  'provider',
  'meta-data',
  'uses-library',
];

/// `android:name` when present, otherwise a sorted attribute signature so
/// nameless elements (e.g. `<uses-feature android:glEsVersion="…">`) merge
/// deterministically and re-runs stay idempotent.
String elementMergeKey(XmlElement element) {
  final name = element.getAttribute('name', namespaceUri: androidNamespaceUri);
  if (name != null) return name;
  final parts = [
    for (final a in element.attributes) '${a.name.qualified}=${a.value}',
  ]..sort();
  return parts.join('&');
}

/// Removes `tools:` attributes from [element] and its descendants: the app
/// manifest does not declare the tools namespace, so copied attributes with
/// that prefix render as unbound prefixes and fail aapt2 link — and they
/// are Gradle-merger directives anyway, meaningless to aapt2.
XmlElement _stripToolsAttributes(XmlElement element) {
  void strip(XmlElement e) => e.attributes.removeWhere(
        (a) =>
            a.name.namespaceUri == toolsNamespaceUri || a.name.prefix == 'tools',
      );
  strip(element);
  element.descendantElements.forEach(strip);
  return element;
}
