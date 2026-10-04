/// The unit declaration (ADR-0037 §1): declared ONCE; every patch after
/// this is derived by `oka ship` from the working tree and the channel
/// state. Never hand-write patch code.
library;

import 'package:oka_update/oka_update.dart';

const patchUnits = UnitsSpec(revision: 'baseline', units: [
  PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
]);
