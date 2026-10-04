/// A patch-unit library for the air-channel showcase (ADR-0037): this
/// file belongs to the `feature` unit declared in
/// `tool/patch_units.dart`, so body-only edits here ship store-free via
/// `oka ship`.
library;

/// The unit's demo value; patches flip this in a running program.
String featureLabel() => 'feature-v1';
