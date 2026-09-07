import 'package:meta/meta.dart';

/// Typed, const-constructible AppGallery release metadata (ADR-0014 P2).
///
/// The non-secret half of the publish plan: what is released, to which AGC
/// channel, with which release notes. Release notes are **file paths**
/// (language → project-relative path), never inlined content — the tier
/// rule keeps text authoring out of typed config and the file contents out
/// of state (the upload step reads them at publish time only).
@immutable
class HuaweiReleaseConfig {
  const HuaweiReleaseConfig({
    this.appId = '',
    this.track = defaultTrack,
    this.releaseNotes = const [],
    this.phasePercent = 100,
    this.releaseDate = '',
  });

  /// The AGC release channel: `'beta'` (open testing) or `'production'`.
  static const String defaultTrack = 'beta';

  /// AppGallery Connect app id (numeric, from AGC console — not a secret).
  final String appId;

  /// Release channel ([defaultTrack] or `'production'`).
  final String track;

  /// Staged-rollout percentage (100 = full release).
  final int phasePercent;

  /// Scheduled release date (`yyyy-MM-dd`), empty = as soon as approved.
  final String releaseDate;

  /// Release notes as (language, file) pairs — file paths only.
  final List<AgcReleaseNote> releaseNotes;

  HuaweiReleaseConfig copyWith({
    final String? appId,
    final String? track,
    final int? phasePercent,
    final String? releaseDate,
    final List<AgcReleaseNote>? releaseNotes,
  }) =>
      HuaweiReleaseConfig(
        appId: appId ?? this.appId,
        track: track ?? this.track,
        phasePercent: phasePercent ?? this.phasePercent,
        releaseDate: releaseDate ?? this.releaseDate,
        releaseNotes: releaseNotes ?? this.releaseNotes,
      );

  /// Non-secret metadata rendered into the publish plan (the dry-run law:
  /// the plan describes exactly what a real run would send).
  Map<String, String> get planMetadata => {
        'appId': appId,
        'phasePercent': '$phasePercent',
        if (releaseDate.isNotEmpty) 'releaseDate': releaseDate,
        if (releaseNotes.isNotEmpty)
          'releaseNotes': releaseNotes
              .map((final n) => '${n.language}:${n.file}')
              .join(', '),
      };

  /// The submit payload for the AGC `app-submit` call — non-secret values
  /// only (release-note *contents* are read from the files at publish time
  /// and placed under `releaseNotes` by the step; they never enter state).
  Map<String, dynamic> submitPayload({
    required final List<({String language, String content})> releaseNoteContents,
  }) =>
      {
        'track': track,
        'release': {
          'phasePercent': phasePercent,
          if (releaseDate.isNotEmpty) 'releaseDate': releaseDate,
          'releaseNotes': [
            for (final n in releaseNoteContents)
              {'language': n.language, 'content': n.content},
          ],
        },
      };

  @override
  bool operator ==(final Object other) =>
      other is HuaweiReleaseConfig &&
      other.appId == appId &&
      other.track == track &&
      other.phasePercent == phasePercent &&
      other.releaseDate == releaseDate &&
      _notesEqual(other.releaseNotes, releaseNotes);

  @override
  int get hashCode => Object.hash(
        appId,
        track,
        phasePercent,
        releaseDate,
        Object.hashAll(releaseNotes),
      );

  @override
  String toString() => 'HuaweiReleaseConfig(appId: $appId, track: $track, '
      'phasePercent: $phasePercent%, notes: '
      '${releaseNotes.map((final n) => '${n.language}:${n.file}').join(', ')})';
}

bool _notesEqual(final List<AgcReleaseNote> a, final List<AgcReleaseNote> b) =>
    a.length == b.length &&
    a.indexed.every((final e) => b[e.$1] == e.$2);

/// One release-note entry: the language tag and the **file path** holding
/// the note text (path reference, not content — the ADR-0014 tier rule).
@immutable
class AgcReleaseNote {
  const AgcReleaseNote({required this.language, required this.file});

  /// BCP-47 language tag, e.g. `en`, `zh-CN`, `ru`.
  final String language;

  /// Project-relative path to the note text file, e.g. `whatsnew-en.txt`.
  final String file;

  @override
  String toString() => 'AgcReleaseNote($language: $file)';

  @override
  bool operator ==(final Object other) =>
      other is AgcReleaseNote &&
      other.language == language &&
      other.file == file;

  @override
  int get hashCode => Object.hash(language, file);
}
