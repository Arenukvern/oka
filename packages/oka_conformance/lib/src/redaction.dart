import 'package:oka_core/oka_core.dart';

/// Thrown by [expectNoSecretMaterial] when dumped text (state, logs, plans,
/// events, request dumps) contains secret material.
class SecretMaterialException implements Exception {
  SecretMaterialException({
    required this.context,
    required this.findings,
  });

  /// What was dumped, e.g. `'PipelineState snapshot'`.
  final String context;

  /// Human-readable findings (what leaked and where).
  final List<String> findings;

  /// Multi-line failure text: context plus every finding.
  @override
  String toString() =>
      'secret material leaked into $context:\n'
      '${findings.map((final f) => '  - $f').join('\n')}';
}

/// Asserts [output] — any dumped text a target produces: a
/// [PipelineState] snapshot, log lines, a [PublishPlan] rendering, step
/// result data, recorded request headers — contains **no secret material**
/// (ADR-0014 law 3, as a reusable assertion):
///
/// - every [refs]' [CredentialRef.explicitPath] must be absent (credential
///   refs may appear only via their redacting `toString()`);
/// - every [forbidden] pattern (the synthetic credential material markers
///   the fixture defines) must be absent.
///
/// Throws [SecretMaterialException] naming every finding.
void expectNoSecretMaterial(
  final String output, {
  final Iterable<CredentialRef> refs = const [],
  final Iterable<Pattern> forbidden = const [],
  final String context = 'output',
}) {
  final findings = <String>[];
  for (final ref in refs) {
    final path = ref.explicitPath;
    if (path != null && path.isNotEmpty && output.contains(path)) {
      findings.add(
        'credential path "$path" (${ref.target}/${ref.kind}) appears '
        'verbatim — refs must render redacted ($ref)',
      );
    }
  }
  for (final f in forbidden) {
    final match = f.allMatches(output).firstOrNull;
    if (match != null) {
      final shown = match.group(0)!;
      findings.add(
        'forbidden material matches at ${output.indexOf(shown)} — pattern '
        '${_render(f)} (showing only the pattern, never the value)',
      );
    }
  }
  if (findings.isNotEmpty) {
    throw SecretMaterialException(context: context, findings: findings);
  }
}

String _render(final Pattern p) => p is RegExp ? '/${p.pattern}/' : '"$p"';

/// Asserts a full [PipelineState] carries no secret material and respects
/// the ADR-0014 value-type law (refs, booleans, numbers, plans, path/id
/// strings only) — usable on *real-run* states too, where
/// `auditPublishConformance` (dry-run only) does not reach.
void expectStateRedacted(
  final PipelineState state, {
  final Iterable<CredentialRef> refs = const [],
  final Iterable<Pattern> forbidden = const [],
  final String context = 'PipelineState snapshot',
}) {
  final dump = StringBuffer();
  for (final entry in state.snapshot.entries) {
    dump
      ..writeln('${entry.key}: ${entry.value}')
      ..writeln('${entry.key}.type: ${entry.value.runtimeType}');
    final value = entry.value;
    final allowed = value == null ||
        value is bool ||
        value is num ||
        value is String ||
        value is CredentialRef ||
        value is PublishPlan;
    if (!allowed) {
      final finding = 'state key "${entry.key}" holds a '
          '${value.runtimeType} — only refs, booleans, numbers, plans, and '
          'path/id strings may enter PipelineState (ADR-0014)';
      throw SecretMaterialException(
        context: context,
        findings: [finding],
      );
    }
  }
  expectNoSecretMaterial(
    dump.toString(),
    refs: refs,
    forbidden: forbidden,
    context: context,
  );
}
