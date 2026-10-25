/// Manifest placeholder resolution for the no-Gradle manifest merger.
///
/// Gradle's manifest merger substitutes the build's placeholders before a
/// library manifest is folded into the app manifest. aapt2 does not: it links
/// the manifest it is handed. A library that declares a placeholder-derived
/// name therefore loses that declaration in a no-Gradle build — AndroidX
/// core declares
/// `${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, the
/// permission AndroidX needs to register a non-exported dynamic receiver
/// on API 26..32. Dropping it is not a link error; it fails at runtime.
///
/// This unit resolves the placeholders the build actually knows:
///
/// - `applicationId` — the app's install-time package. The app manifest's
///   `package` attribute *is* that package (oka never renames the package
///   at link time), so the app manifest is the source of truth.
///
/// A placeholder the build cannot resolve stays unresolved and is reported:
/// the merger refuses the element and names the placeholder. Nothing is
/// guessed, and a refusal stays visible instead of silently dropping a
/// declaration the app needs.
library;

import 'package:xml/xml.dart';

/// The manifest placeholders a no-Gradle build can resolve.
final class ManifestPlaceholders {
  /// Creates the placeholders of an app with [applicationId].
  const ManifestPlaceholders({required this.applicationId});

  /// The app's install-time package name (e.g. `dev.example.app`).
  final String applicationId;

  /// Matches a `${name}` placeholder.
  static final RegExp placeholderPattern = RegExp(r'\$\{([^{}]+)\}');

  /// Substitutes the known placeholders in [value].
  ///
  /// An unknown placeholder is left untouched, so the caller can see that
  /// it was not resolved.
  String substitute(String value) => value.replaceAllMapped(
        placeholderPattern,
        (match) => match.group(1) == 'applicationId'
            ? applicationId
            : match.group(0)!,
      );

  /// Substitutes the known placeholders in every attribute of [element].
  ///
  /// The element is mutated in place — pass a copy when the source element
  /// must stay untouched.
  void substituteInto(XmlElement element) {
    for (final attribute in element.attributes) {
      attribute.value = substitute(attribute.value);
    }
    element.descendantElements.forEach(substituteInto);
  }

  /// The placeholder names in [value] that no substitution resolved.
  ///
  /// Call this on a substituted value: whatever is left is unresolved.
  static Set<String> unresolvedIn(String value) => {
        for (final match in placeholderPattern.allMatches(value))
          match.group(1)!,
      };

  /// The placeholder names in the attributes of [element] that no
  /// substitution resolved.
  static Set<String> unresolvedInElement(XmlElement element) => {
        for (final attribute in element.attributes)
          ...unresolvedIn(attribute.value),
      };
}
