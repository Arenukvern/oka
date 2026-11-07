import 'package:archive/archive.dart';

/// Fixed ZIP entry timestamps for oka-packed APK/AAB artifacts (ADR-0007).
///
/// Uses 1980-01-01 00:00:00 UTC (minimum DOS-representable date). The workspace
/// requires `archive` ≥ 4.6.0, which clamps sub-1980 [ArchiveFile.lastModTime]
/// values via `_dosRange` so encodes are timezone-stable (unlike `0`, which on
/// older `archive` releases mapped to host-local DOS fields).
const int okaZipEntryUnixSeconds = 315532800; // DateTime.utc(1980, 1, 1)

/// Applies [okaZipEntryUnixSeconds] to [file] for deterministic zip metadata.
void stampOkaZipEntry(ArchiveFile file) {
  file
    ..lastModTime = okaZipEntryUnixSeconds
    ..creationTime = okaZipEntryUnixSeconds;
}
