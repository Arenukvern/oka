/// Build provenance facts as a typed pipeline artifact (ADR-0029 D1).
///
/// Every step already computes the facts a release diagnosis needs — which
/// engine jar `libflutter.so` came from, which `gen_snapshot` built
/// `libapp.so`, which pub resolution the AOT was compiled against. This
/// library records those facts next to the artifact they describe, so a
/// post-mortem is a lookup instead of an archaeology dig.
///
/// Extension contract for developers composing on top of oka:
///
/// 1. **From a custom step** — append a fact while running; it lands in the
///    build's `oka-provenance.json` automatically:
///
///    ```dart
///    class MyStep extends BuildStep {
///      @override
///      Future<StepResult> run(BuildContext ctx, PipelineState state) async {
///        state.addProvenanceFact(
///          const ProvenanceFact('my_plugin.variant', 'fast'),
///        );
///        return StepResult.success();
///      }
///    }
///    ```
///
/// 2. **Declaratively** — pass standalone contributors to
///    [ProvenanceStampStep] when composing the step list:
///
///    ```dart
///    ProvenanceStampStep(contributors: [MyFacts()])
///    ```
///
/// Facts are keyed strings with JSON-primitive values; later contributions
/// with the same key overwrite earlier ones (step order decides), and the
/// stamp step prints the final record so provenance is visible in every
/// build log.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../android_artifacts.dart';
import '../android_state.dart';
import 'apk_layout.dart';

/// Schema version of the provenance record. Bump on breaking key changes.
const provenanceSchemaVersion = 1;

/// Well-known fact keys (dot-namespaced; third parties use their own
/// prefix — collide-proof by convention, e.g. `my_plugin.variant`).
const factEngineVariant = 'engine.variant';
const factEngineJarSha256 = 'engine.jar_sha256';
const factEngineLibflutterSha256 = 'engine.libflutter_sha256';
const factAotSnapshotSha256 = 'aot.snapshot_sha256';
const factAotBuildId = 'aot.build_id';
const factResolutionPackageConfigSha256 = 'resolution.package_config_sha256';
const factResolutionPubspecLockSha256 = 'resolution.pubspec_lock_sha256';
const factAssembleFingerprint = 'assemble.fingerprint';

/// A single provenance fact: namespaced key + JSON-primitive value.
class ProvenanceFact {
  const ProvenanceFact(this.key, this.value);

  final String key;
  final Object value; // String | num | bool

  Map<String, Object> toJson() => {'key': key, 'value': value};

  // Named decode pairs read better at call sites than private constructors.
  // ignore: prefer_constructors_over_static_methods
  static ProvenanceFact fromJson(final Map<String, dynamic> json) =>
      ProvenanceFact(json['key']! as String, json['value']! as Object);
}

/// Extension point for developers composing on top of oka (ADR-0029 D1):
/// anything that can name facts about this build. Steps may implement this
/// too, but appending to `state.addProvenanceFact(...)` inside `run()` is
/// usually simpler and composes with caching (facts are recorded per actual
/// execution).
// The contract is exactly one fact batch; more would be two contracts.
// ignore: one_member_abstracts
abstract interface class ProvenanceContributor {
  List<ProvenanceFact> provenanceFacts(
    final BuildContext ctx,
    final PipelineState state,
  );
}

/// The provenance record stamped into the artifact
/// (`flutter_assets/oka-provenance.json`).
class ProvenanceRecord {
  ProvenanceRecord(this.facts)
    : assert(
        facts.every(
          (final f) => f.value is String || f.value is num || f.value is bool,
        ),
        'provenance fact values must be JSON primitives',
      );

  final List<ProvenanceFact> facts;

  /// Latest value for [key], or null.
  Object? fact(final String key) {
    for (final f in facts) {
      if (f.key == key) return f.value;
    }
    return null;
  }

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'schema': provenanceSchemaVersion,
    'facts': {for (final f in facts) f.key: f.value},
  });

  // ignore: prefer_constructors_over_static_methods, see ProvenanceFact.fromJson.
  static ProvenanceRecord decode(final String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    final factsJson = data['facts'];
    final list = <ProvenanceFact>[];
    if (factsJson is Map<String, dynamic>) {
      // Newer schema: facts object keyed by fact key.
      for (final entry in factsJson.entries) {
        list.add(ProvenanceFact(entry.key, entry.value as Object));
      }
    } else if (factsJson is List) {
      for (final f in factsJson) {
        list.add(ProvenanceFact.fromJson(f as Map<String, dynamic>));
      }
    }
    return ProvenanceRecord(list);
  }
}

/// Collects facts from the state list and [contributors] (declarative
/// extras), last-writer-wins per key, preserving first-seen order. Pure.
ProvenanceRecord collectProvenance(
  final List<ProvenanceFact> stateFacts,
  final List<ProvenanceContributor> contributors, {
  final BuildContext? ctx,
  final PipelineState? state,
}) {
  final ordered = <ProvenanceFact>[];
  final byKey = <String, ProvenanceFact>{};
  void add(final ProvenanceFact f) {
    final existing = byKey[f.key];
    if (existing == null) {
      byKey[f.key] = f;
      ordered.add(f);
    } else if (existing.value != f.value) {
      byKey[f.key] = f;
      ordered[ordered.indexOf(existing)] = f;
    }
  }

  stateFacts.forEach(add);
  for (final c in contributors) {
    c.provenanceFacts(ctx!, state!).forEach(add);
  }
  return ProvenanceRecord(ordered);
}

/// SHA-256 of a file (hex), or null when the file does not exist.
Future<String?> fileSha256(final String path) async {
  final f = File(path);
  if (!f.existsSync()) return null;
  return sha256.convert(await f.readAsBytes()).toString();
}

/// Stamps the aggregated provenance record into
/// `flutter_assets/oka-provenance.json` inside the build's staged assets —
/// the artifact then carries its own birth certificate (ADR-0029 D1).
///
/// Composes like any step: builtin steps contribute facts through the state
/// list; third-party steps do the same; standalone [ProvenanceContributor]s
/// plug in via the constructor. Run it any time after the facts' sources
/// have run and before packaging.
class ProvenanceStampStep extends BuildStep {
  ProvenanceStampStep({this.contributors = const []});

  /// Declarative contributors composed in the project's step list.
  final List<ProvenanceContributor> contributors;

  @override
  String get name => 'provenance-stamp';

  @override
  Set<Artifact<Object>> get requires => {flutterAssetsDir};

  @override
  Set<Artifact<Object>> get provides => {provenancePath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final assetsDir = state.flutterAssetsDir;
    if (assetsDir == null || assetsDir.isEmpty) {
      return StepResult.failure(
        'provenance-stamp: no staged flutter_assets — place this step '
        'after flutter-assemble',
      );
    }
    state.addProvenanceFact(
      ProvenanceFact('build.mode', ctx.mode.name),
    );
    state.addProvenanceFact(
      ProvenanceFact('build.abis', state.abis.join(',')),
    );
    final record = collectProvenance(
      state.provenanceFacts,
      contributors,
      ctx: ctx,
      state: state,
    );
    final dest = File(
      p.join(assetsDir, 'oka-provenance.json'),
    );
    await dest.parent.create(recursive: true);
    await dest.writeAsString(record.encode(), flush: true);
    state.provenancePath = dest.path;
    print(
      '🔏 provenance: ${record.facts.length} fact(s) → '
      '${p.relative(dest.path, from: ctx.projectPath)}',
    );
    if (ctx.verbose) {
      for (final f in record.facts) {
        print('   ${f.key} = ${f.value}');
      }
    }
    return StepResult.success();
  }
}

/// Reads the provenance record out of a built APK/AAB without unzipping to
/// disk: `unzip -p <artifact> assets/flutter_assets/oka-provenance.json`.
/// Null when the artifact predates ADR-0029 (no record inside).
Future<ProvenanceRecord?> readProvenanceFromArtifact(
  final String artifactPath,
) async {
  final r = await Process.run('unzip', [
    '-p',
    artifactPath,
    'assets/flutter_assets/oka-provenance.json',
  ]);
  if (r.exitCode != 0) return null;
  final out = (r.stdout as String).trim();
  if (out.isEmpty) return null;
  try {
    return ProvenanceRecord.decode(out);
  } on FormatException {
    return null;
  }
}

/// Normalizes an ABI for provenance storage.
String provenanceAbi(final String abi) => normalizeAbi(abi);
