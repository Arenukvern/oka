/// Declarative patch-unit spec (ADR-0031 §1): units map a name to a set of
/// libraries; the generator/kernel layer draws the file boundaries from this.
library;

class UnitsSpec {
  const UnitsSpec({required this.revision, required this.units});

  /// Revision id baked into the generated manifest.
  final String revision;

  /// Declared patch units, in stable order.
  final List<PatchUnit> units;
}

class PatchUnit {
  const PatchUnit({required this.name, required this.libraries});

  /// Unit id as referenced by the composition and manifests.
  final String name;

  /// Library paths (package-relative) whose code belongs to this unit.
  /// Everything a unit's libraries reach that is NOT in some declared unit
  /// belongs to the core and is public-by-design.
  final List<String> libraries;
}
