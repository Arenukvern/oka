/// Content-addressed artifact store with delta chains (ADR-0043).
///
/// Git stores pointers; bytes live here. Snapshot cadence emerges from
/// measured delta ratios — the "diff → diff… → snapshot" shape, with no
/// configuration and no cron.
library;

export 'src/codec.dart';
export 'src/pointer.dart';
export 'src/rule.dart';
export 'src/store.dart';
