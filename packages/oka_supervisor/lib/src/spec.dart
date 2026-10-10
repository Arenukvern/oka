/// Desired state: typed component specs over the composition substrate
/// (ADR-0040 decisions 1, 4, 8).
///
/// Specs are Dart values — the house style. Shape and trigger are
/// *properties* of any component, never a kind taxonomy: one spec with
/// [WatchTrigger] *is* the lane, one with [IntervalTrigger] *is* the
/// schedule. Providers are named, not embedded; a [ProviderFactory]
/// resolves names at composition time, so the substrate's
/// validate-before-side-effects contract applies unchanged.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:resource_composition/resource_composition.dart';

/// What "desired" means for a component between converges.
enum SupervisionShape {
  /// Desired: running. Death within the restart budget converges back to
  /// running; exhausting the budget converges to a `giveUp` finding.
  service,

  /// Desired: succeeded once per revision (re-run when an
  /// [IntervalTrigger] comes due). Exit 0 is success; failure retries
  /// within the same budget as services.
  job,
}

/// When a component should run. A property of any spec, never a kind.
/// Rung-1 enforcement: intervals gate job re-runs in `converge`; watch
/// triggers are declared and recorded, enforced by the resident rung —
/// rung 1 adds no second file watcher (ADR-0040 decision 4).
sealed class Trigger {
  const Trigger();

  /// Stable summary recorded in the registry record and facts.
  String describe();
}

/// Nothing scheduled; services converge to running, jobs run once per
/// revision.
final class NoTrigger extends Trigger {
  const NoTrigger();

  @override
  String describe() => 'none';
}

/// Run when files under [roots] change (declarative; the resident rung or
/// an existing watcher enforces).
final class WatchTrigger extends Trigger {
  const WatchTrigger({
    required this.roots,
    this.extensions = const <String>[],
    this.debounce = const Duration(milliseconds: 500),
  });

  final List<String> roots;
  final List<String> extensions;
  final Duration debounce;

  @override
  String describe() =>
      'watch:${roots.join('|')}'
      '${extensions.isEmpty ? '' : ' [${extensions.join('|')}]'}';
}

/// Run at most once per [period] (the recorded nightly-lane shape: an
/// interval, not a cron parser — an ADR-0040 non-goal).
final class IntervalTrigger extends Trigger {
  const IntervalTrigger({required this.period});

  final Duration period;

  @override
  String describe() => 'interval:${period.inSeconds}s';
}

/// Steady-state policy: the budgeted restart ledger a spec declares
/// (ADR-0040 decision 3). The one-shot runner never restarts anything;
/// only the supervisor does, only within this budget, only for records it
/// owns.
final class SupervisionPolicy {
  const SupervisionPolicy({
    this.shape = SupervisionShape.service,
    this.maxRestarts = 3,
    this.restartWindow = const Duration(minutes: 2),
    this.revision = 1,
  });

  final SupervisionShape shape;

  /// Restart budget: at most this many restarts within [restartWindow];
  /// exhausting it yields a terminal `giveUp` finding until [revision]
  /// changes (an explicit human or agent act) or the window ages out.
  final int maxRestarts;

  final Duration restartWindow;

  /// Bump to force a re-converge (restart or re-run) and reset the
  /// restart budget. The reset is the revision bump — never a silent
  /// default.
  final int revision;
}

/// One declared component of the desired state.
final class ComponentSpec {
  const ComponentSpec({
    required this.id,
    required this.providerName,
    this.dependsOn = const <String>[],
    this.requires = const <String>[],
    this.provides = const <String>[],
    this.readiness,
    this.policy = const SupervisionPolicy(),
    this.trigger = const NoTrigger(),
    this.env = const <String, String>{},
  });

  /// Stable, unique within the desired state.
  final String id;

  /// Name resolved through a [ProviderFactory]; mechanics live in the
  /// provider, never in the spec.
  final String providerName;

  final List<String> dependsOn;
  final List<String> requires;
  final List<String> provides;

  /// Declared readiness, resolved by the provider per the substrate
  /// dialects.
  final Readiness? readiness;

  final SupervisionPolicy policy;
  final Trigger trigger;

  /// Declared for visibility and revision hashing; mechanics flow through
  /// provider construction (the composition root injects env when the
  /// provider takes it), so a spec never hides an env knob.
  final Map<String, String> env;

  /// Stable content hash of the declaration. The planner restarts on
  /// revision drift and the drift check composes the spec's own
  /// [SupervisionPolicy.revision] with this hash.
  String get revisionHash {
    final digest = sha1.convert(utf8.encode(toCanonicalJson()));
    return digest.toString().substring(0, 12);
  }

  /// Deterministic JSON projection (record summaries and hashing only —
  /// never an authoring surface, ADR-0040 decision 8).
  String toCanonicalJson() {
    final map = <String, Object?>{
      'id': id,
      'provider': providerName,
      'dependsOn': dependsOn,
      'requires': requires,
      'provides': provides,
      'readiness': readiness?.describe(),
      'shape': policy.shape.name,
      'maxRestarts': policy.maxRestarts,
      'restartWindowS': policy.restartWindow.inSeconds,
      'revision': policy.revision,
      'trigger': trigger.describe(),
      'env': env,
    };
    return const _CanonicalJson().encode(map);
  }
}

/// The whole desired state: specs plus the defaults the substrate needs.
final class DesiredState {
  const DesiredState({
    required this.specs,
    this.readinessBudget = const Duration(seconds: 30),
  });

  final List<ComponentSpec> specs;

  /// Default readiness budget for specs without an override.
  final Duration readinessBudget;

  /// Builds the substrate composition. Throws [ArgumentError] when a
  /// provider name cannot be resolved — invalid states fail before any
  /// side effect.
  Composition composition(final ProviderFactory factory) {
    final unknown = <String>{
      for (final spec in specs)
        if (!_resolves(factory, spec.providerName)) spec.providerName,
    };
    if (unknown.isNotEmpty) {
      throw ArgumentError(
        'unknown provider name(s): ${unknown.join(', ')}; the factory must '
        'resolve every declared provider before converge',
      );
    }
    return Composition(
      components: [
        for (final spec in specs)
          Component(
            id: spec.id,
            provider: factory(spec.providerName),
            dependsOn: spec.dependsOn,
            requires: [
              for (final ref in spec.requires) OutputRef<Object?>(ref),
            ],
            provides: [
              for (final ref in spec.provides) OutputRef<Object?>(ref),
            ],
            readiness: spec.readiness,
            lifecycle: Lifecycle(
              scope: spec.policy.shape == SupervisionShape.service
                  ? ResourceScope.session
                  : ResourceScope.ephemeral,
              onCrash: CrashPolicy.reconcile,
            ),
          ),
      ],
      readinessBudget: readinessBudget,
    );
  }

  /// Validates provider resolution, policy sanity, and the substrate
  /// graph — zero side effects, providers never contacted.
  CompositionReport validate(final ProviderFactory factory) =>
      composition(factory).validate();

  /// Specs by id, declaration order preserved.
  Map<String, ComponentSpec> byId() => {
        for (final spec in specs) spec.id: spec,
      };

  static bool _resolves(final ProviderFactory factory, final String name) {
    try {
      factory(name);
      return true;
    } on Object {
      return false;
    }
  }
}

/// Creates providers by declared name. Pure at composition time: the
/// returned provider must not be contacted until the converge driver acts.
typedef ProviderFactory = ResourceProvider Function(String name);

/// Canonical JSON encoding for revision hashing: sorted keys, no spaces.
final class _CanonicalJson {
  const _CanonicalJson();

  String encode(final Object? value) {
    final buffer = StringBuffer();
    _write(value, buffer);
    return buffer.toString();
  }

  void _write(final Object? value, final StringBuffer buffer) {
    switch (value) {
      case null:
        buffer.write('null');
      case final bool v:
        buffer.write(v ? 'true' : 'false');
      case final num v:
        buffer.write(v);
      case final String v:
        buffer
          ..write('"')
          ..write(v.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n'))
          ..write('"');
      case final List<Object?> v:
        buffer.write('[');
        for (var i = 0; i < v.length; i++) {
          if (i > 0) buffer.write(',');
          _write(v[i], buffer);
        }
        buffer.write(']');
      case final Map<Object?, Object?> v:
        final keys = v.keys.map((final k) => '$k').toList()..sort();
        buffer.write('{');
        for (var i = 0; i < keys.length; i++) {
          if (i > 0) buffer.write(',');
          _write(keys[i], buffer);
          buffer.write(':');
          _write(v[keys[i]], buffer);
        }
        buffer.write('}');
      default:
        buffer.write('"${value.runtimeType}"');
    }
  }
}
