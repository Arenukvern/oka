/// The composed web shell (ADR-0016): spec + contributions → one value.
///
/// Composition is pure and explicit — the same value the emitters render
/// and the validators check. Ordering law: head entries are ordered by
/// [WebHeadPhase] (`preconnect` < `storeSdk` < `app`), preserving
/// declaration order within a phase; scalar overrides (base href, manifest
/// fields, dart-defines) resolve last-declaration-wins across
/// contributions over the spec.
library;

import 'package:meta/meta.dart';

import 'contribution.dart';
import 'spec/body_entry.dart';
import 'spec/head_entry.dart';
import 'spec/web_shell_spec.dart';

/// The composed shell: a [WebShellSpec] plus explicitly composed
/// [WebShellContribution]s. Pure value — no I/O, no merging beyond the
/// documented last-wins override resolution.
@immutable
class WebShell {
  const WebShell({required this.spec, this.contributions = const []});

  /// The project shell spec (identity + defaults).
  final WebShellSpec spec;

  /// Explicitly composed contributions, in declaration order.
  final List<WebShellContribution> contributions;

  /// Effective document title (the spec title; overrides apply to the
  /// manifest, not the title tag).
  String get title => spec.title;

  /// Effective base href: the last contribution override wins over the
  /// spec; falls back to `'/'`.
  String get baseHref {
    for (final c in contributions.reversed) {
      final override = c.baseHref;
      if (override != null && override.isNotEmpty) return override;
    }
    return spec.baseHref;
  }

  /// Head entries, phase-ordered: `preconnect` < `storeSdk` < `app`;
  /// within a phase, declaration order (spec extra meta first, then
  /// contributions in order). Stable sort.
  List<WebHeadEntry> get head {
    final all = <WebHeadEntry>[
      ...spec.metaEntries,
      for (final c in contributions) ...c.head,
    ];
    final sorted = [...all]..sort(
        (final a, final b) => a.phase.order.compareTo(b.phase.order),
      );
    return sorted;
  }

  /// Body entries in declaration order (spec order first, then
  /// contributions in order) — body entries carry no phases.
  List<WebBodyEntry> get body => [
        for (final c in contributions) ...c.body,
      ];

  /// Effective PWA manifest fields: contribution overrides applied in
  /// declaration order over the spec's manifest defaults; empty spec
  /// manifest fields backfill from the spec's top-level identity fields
  /// (title → name/short_name, description → description, colors,
  /// display, orientation, start_url, icons).
  PwaManifestSpec get manifest {
    var m = spec.manifest;
    var icons = spec.icons;
    for (final c in contributions) {
      final override = c.manifest;
      if (override == null) continue;
      m = m.apply(override);
      if (override.icons != null) icons = override.icons!;
    }
    final name = m.name.isNotEmpty ? m.name : spec.title;
    return PwaManifestSpec(
      name: name,
      shortName: m.shortName.isNotEmpty ? m.shortName : name,
      startUrl: m.startUrl.isNotEmpty ? m.startUrl : spec.startUrl,
      display: m.display.isNotEmpty ? m.display : spec.display,
      orientation: m.orientation.isNotEmpty
          ? m.orientation
          : spec.orientation,
      themeColor: m.themeColor.isNotEmpty ? m.themeColor : spec.themeColor,
      backgroundColor: m.backgroundColor.isNotEmpty
          ? m.backgroundColor
          : spec.backgroundColor,
      description:
          m.description.isNotEmpty ? m.description : spec.description,
      icons: icons,
      preferRelatedApplications: m.preferRelatedApplications,
    );
  }

  /// Effective dart-defines for `flutter build web`: spec/base defines
  /// come from the build context; this value is only the contribution
  /// layer (later contributions win).
  Map<String, String> get contributionDartDefines {
    final merged = <String, String>{};
    for (final c in contributions) {
      merged.addAll(c.dartDefines);
    }
    return Map.unmodifiable(merged);
  }

  /// Human/agent-readable composition summary — what `oka explain` shows
  /// before anything is written (ADR-0016 W1 wires this into explain).
  List<String> describeLines() {
    final entries = head;
    int countOf(final WebHeadPhase phase) =>
        entries.where((final e) => e.phase == phase).length;
    final headSummary =
        '(${WebHeadPhase.preconnect.name}: ${countOf(WebHeadPhase.preconnect)}, '
        '${WebHeadPhase.storeSdk.name}: ${countOf(WebHeadPhase.storeSdk)}, '
        '${WebHeadPhase.app.name}: ${countOf(WebHeadPhase.app)})';
    final manifestSummary =
        'manifest: name="${manifest.name}", display=${manifest.display}, '
        'orientation=${manifest.orientation}';
    return [
      'shell: "$title"',
      'base href: $baseHref',
      'head entries: ${entries.length} $headSummary',
      'body entries: ${body.length}',
      manifestSummary,
      for (final e in entries) '  head: ${e.phase.name} — $e',
      for (final e in body) '  body: $e',
    ];
  }

  /// Debug string: title plus contribution count.
  @override
  String toString() =>
      'WebShell("$title", ${contributions.length} contributions)';
}
