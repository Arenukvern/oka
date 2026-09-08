import '../config/build_context.dart';
import '../pipeline/pipeline.dart';
import 'target.dart';

/// One step of a described target chain (ADR-0015): its name plus the
/// artifact ids it requires and provides — the same summary `oka explain`
/// prints for platform pipelines.
class TargetStepDescription {
  const TargetStepDescription({
    required this.name,
    required this.requires,
    required this.provides,
  });

  factory TargetStepDescription.fromJson(final Map<String, dynamic> json) =>
      TargetStepDescription(
        name: json['name']?.toString() ?? '',
        requires: [
          for (final r in (json['requires'] as List? ?? const [])) r.toString(),
        ],
        provides: [
          for (final p in (json['provides'] as List? ?? const [])) p.toString(),
        ],
      );

  /// Step name ([BuildStep.name]).
  final String name;

  /// Artifact ids this step requires from upstream steps.
  final List<String> requires;

  /// Artifact ids this step provides to downstream steps.
  final List<String> provides;

  Map<String, dynamic> toJson() => {
        'name': name,
        'requires': requires,
        'provides': provides,
      };
}

/// The compiled, validated step chain of a [Target] — described, never
/// executed (ADR-0015). This is the value behind `oka explain --targets`:
/// the same validated-plan surface as builds ([Pipeline.validate]), with
/// no tool invocation anywhere in the path.
class TargetChainDescription {
  const TargetChainDescription({
    required this.name,
    required this.description,
    required this.steps,
    this.details = const [],
    this.validationError,
  });

  factory TargetChainDescription.fromJson(final Map<String, dynamic> json) =>
      TargetChainDescription(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        steps: [
          for (final s in (json['steps'] as List? ?? const []))
            TargetStepDescription.fromJson(
              (s as Map).cast<String, dynamic>(),
            ),
        ],
        validationError: json['validationError']?.toString(),
        details: [
          for (final d in (json['details'] as List? ?? const [])) d.toString(),
        ],
      );

  /// Target name ([Target.name]).
  final String name;

  /// One-line description ([Target.description]).
  final String description;

  /// The compiled step chain, in order.
  final List<TargetStepDescription> steps;

  /// Pure, platform-agnostic explain details ([Target.explainDetails]) —
  /// extra lines `oka explain --targets` prints after the step chain.
  final List<String> details;

  /// Composition-time validation failure from [Pipeline.validate], or null
  /// when the chain is valid.
  final String? validationError;

  bool get isValid => validationError == null;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'steps': [for (final s in steps) s.toJson()],
        'details': details,
        'validationError': validationError,
      };
}

/// Describes [target]'s compiled step chain **without running it** (ADR-0015).
///
/// Pure: calls [Target.compile] (a pure function of the target value + [ctx])
/// and [Pipeline.validate] — no tool invocations, no I/O. The returned
/// [TargetChainDescription.validationError] is the same composition-time
/// failure a real `oka run <target>` would report before executing anything.
TargetChainDescription describeTarget(
  final Target target,
  final BuildContext ctx,
) {
  final steps = target.compile(ctx);
  final pipeline = Pipeline(steps);
  return TargetChainDescription(
    name: target.name,
    description: target.description,
    steps: [
      for (final s in steps)
        TargetStepDescription(
          name: s.name,
          requires: [for (final a in s.requires) a.id],
          provides: [for (final a in s.provides) a.id],
        ),
    ],
    // Pure explain details (ADR-0016 W1) — from composition, never
    // execution.
    details: target.explainDetails(ctx),
    validationError: pipeline.validate(),
  );
}
