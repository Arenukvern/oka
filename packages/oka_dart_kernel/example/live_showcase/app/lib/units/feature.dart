/// The patch unit: everything this file reaches that isn't another declared
/// unit belongs to the core (public-by-design).
///
/// Note for live patches: patch FUNCTION bodies (like `feature()` below).
/// A `const` field's canonical value survives a kernel reload, so value
/// probes must read through freshly-executed code.
library;

const String featureLabel = 'alpha-v1';

String feature() => 'alpha-v1';
