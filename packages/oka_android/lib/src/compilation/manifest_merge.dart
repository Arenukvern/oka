import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

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
/// Returns the number of elements added.
int mergeLibraryManifestsInto({
  required final String appManifestPath,
  required final Iterable<String> libraryManifestPaths,
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

  void mergeInto(
    final XmlElement target,
    final Iterable<String> tags,
    final XmlDocument library,
  ) {
    for (final tag in tags) {
      final existing = {
        for (final e in target.findElements(tag)) elementMergeKey(e),
      };
      // Library manifests nest components under <application>, so search
      // all descendants; app-manifest dedupe reads direct children only.
      for (final element in library.rootElement.findAllElements(tag)) {
        if (element.getAttribute('node', namespace: toolsNamespaceUri) ==
            'remove') {
          continue;
        }
        final key = elementMergeKey(element);
        if (existing.contains(key)) continue;
        // Gradle would substitute manifest placeholders (${applicationId});
        // aapt2 cannot, and a literal placeholder breaks at install time.
        final name = element.getAttribute('name', namespace: androidNamespaceUri);
        if (name != null && name.contains(r'${')) {
          stderr.writeln(
            'oka: manifest merge skipped ${element.name.qualified} '
            '($name) — unsubstituted manifest placeholder',
          );
          continue;
        }
        existing.add(key);
        additions.add((target, _stripToolsAttributes(element.copy())));
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
    final libApplication = library.rootElement.findElements('application').firstOrNull;
    if (libApplication == null) continue;
    mergeInto(application, applicationChildTags, library);
  }

  void addPair(final (XmlElement, XmlElement) pair) =>
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
String elementMergeKey(final XmlElement element) {
  final name = element.getAttribute('name', namespace: androidNamespaceUri);
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
XmlElement _stripToolsAttributes(final XmlElement element) {
  void strip(final XmlElement e) => e.attributes.removeWhere(
        (final a) =>
            a.name.namespaceUri == toolsNamespaceUri || a.name.prefix == 'tools',
      );
  strip(element);
  element.descendantElements.forEach(strip);
  return element;
}
