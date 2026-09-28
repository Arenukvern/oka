import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Foreign build-tool stores (ADR-0028 §4): read-only inventory of the
/// caches other tools own — pub, Gradle, fvm, the Flutter SDK cache — so
/// `oka cache` reports the majority of a machine's build bytes.
///
/// Records carry advisory, user-executed actions only. Oka never deletes
/// another tool's cache, and sizes here are explanatory metadata that never
/// augment storage totals (ADR-0021). AVD state is covered by
/// `AndroidCacheDiagnosticProvider` (kind `emulator`) and stays out of this
/// provider.
final class ForeignStoreDiagnosticProvider implements CacheDiagnosticProvider {
  const ForeignStoreDiagnosticProvider();

  static const _foreignCategories = {
    'dart-pub-cache',
    'gradle-cache',
    'fvm-versions',
    'flutter-sdk-cache',
  };

  @override
  String get id => 'foreign-stores';

  @override
  Future<CacheDiagnosticContribution> inspect(
    final CacheDiagnosticContext context,
  ) async {
    final records = <CacheDiagnosticRecord>[];
    for (final entry in context.storage.locations) {
      final location = entry.location;
      if (!_foreignCategories.contains(location.category)) continue;
      records.add(
        CacheDiagnosticRecord(
          id: CacheDiagnosticIds.resource('foreign-cache', location.path),
          kind: 'foreign-cache',
          label: p.basename(location.path),
          platform: location.platform,
          path: location.path,
          storagePaths: [location.path],
          metadata: {
            'owner': location.ownership,
            'size_bytes': entry.sizeBytes,
            'measurement_complete': entry.complete,
            'prunable_by_oka': false,
            if (location.note != null) 'note': location.note,
          },
          actions: [
            ?_advisoryFor(location.category),
          ],
          observations: [
            CacheDiagnosticObservation(
              source: CacheObservationSource.filesystem,
              status: entry.complete ? 'measured' : 'partial',
              observedAt: context.observedAt,
            ),
          ],
        ),
      );
    }
    return CacheDiagnosticContribution(records: records);
  }

  /// The single official reclamation command for a category, when one
  /// exists. Executed only when the user runs it — never by oka.
  CacheDiagnosticAction? _advisoryFor(final String category) {
    switch (category) {
      case 'dart-pub-cache':
        return const CacheDiagnosticAction(
          id: 'pub-cache-clean',
          label: 'dart pub cache clean (regenerates on next pub get)',
          argv: ['dart', 'pub', 'cache', 'clean'],
          cwd: '.',
          destructive: true,
        );
      case 'gradle-cache':
        return const CacheDiagnosticAction(
          id: 'gradle-stop',
          label:
              'gradle --stop (run before manually removing ~/.gradle caches)',
          argv: ['gradle', '--stop'],
          cwd: '.',
        );
      case 'fvm-versions':
      case 'flutter-sdk-cache':
        return null; // no single official command; the note names the tool
      default:
        return null;
    }
  }
}
