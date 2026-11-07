import 'package:archive/archive.dart';

/// Fixed ZIP entry timestamps for oka-packed APK/AAB artifacts (ADR-0007).
///
/// Uses Unix epoch (`0`). The workspace requires `archive` ≥ 4.6.0, whose
/// `_dosRange` clamp maps pre-1980 [ArchiveFile.lastModTime] values to
/// `1980-01-01` **local** midnight in the MS-DOS time/date fields. That yields
/// timezone-stable DOS metadata (unlike a UTC-midnight stamp such as
/// `315532800`, which encodes host-local hours and drifts across zones).
const int okaZipEntryUnixSeconds = 0;

/// Applies [okaZipEntryUnixSeconds] to [file] for deterministic zip metadata.
void stampOkaZipEntry(ArchiveFile file) {
  file
    ..lastModTime = okaZipEntryUnixSeconds
    ..creationTime = okaZipEntryUnixSeconds;
}
