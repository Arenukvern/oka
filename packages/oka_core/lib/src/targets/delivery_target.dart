import 'package:meta/meta.dart';

import '../composition.dart';
import '../config/build_context.dart';
import '../pipeline/pipeline.dart';
import '../publish/publish_target.dart';
import '../variants/variant.dart';
import 'target.dart';

/// Runs a [PlatformPipeline] as one step inside a delivery chain
/// (ADR-0055).
///
/// The pipeline runs **by const reference** — the delivery never restates
/// its configuration (the Flutter-widget composition law: parents compose
/// typed children, config is not duplicated). The step mirrors the
/// pipeline's result data (e.g. `apk_path`, `web-build-output`) into the
/// shared [PipelineState] so downstream channel steps resolve the
/// produced artifact through the standard ids — the same convention
/// standalone publish targets consume.
@immutable
class RunPipelineStep extends BuildStep {
  /// Wraps the referenced pipeline.
  RunPipelineStep({required this.pipeline});

  /// The platform pipeline that produces the artifact (shared by every
  /// delivery of the same platform).
  final PlatformPipeline pipeline;

  /// Step name: `run-pipeline:<platform>`.
  @override
  String get name => 'run-pipeline:${pipeline.platform}';

  /// Runs the pipeline with the (already variant-transformed) context and
  /// mirrors its result data into [state]. A failing pipeline fails the
  /// step — the outer chain stops before any channel work.
  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) =>
      pipeline.run(ctx).then((result) {
        for (final entry in result.data.entries) {
          if (entry.value != null) state[entry.key] = entry.value;
        }
        return result;
      });

  /// Debug string: the platform it runs.
  @override
  String toString() => 'RunPipelineStep(${pipeline.platform})';
}

/// The ONE named axis of the distribution matrix (ADR-0055): a [Target]
/// that composes **pipeline** (HOW one toolchain builds the artifact — by
/// const reference) + **variant** (WHAT compiles in: entrypoint, defines,
/// overlays, store key) + **channel** (WHERE it publishes — a
/// [PublishTarget]).
///
/// Deliveries are the Flutter-widget composition of the build world:
/// typed children composed as const values, no configuration restated,
/// no delegate re-dispatch. `oka run app-rustore` builds through the
/// referenced pipeline with the variant applied to the context, then runs
/// the channel's publish tail (its dry-run law, delivery gate, and upload
/// come from [PublishTarget.compile] — one implementation of the
/// publishing laws, not a copy).
///
/// ```dart
/// Oka(
///   pipelines: [AndroidPipeline(config: AndroidBuild(packageName: '…'))],
///   targets: [
///     Delivery(
///       name: 'app-google-play',
///       pipeline: androidPipeline,
///       variant: Variant(
///         key: storeKeyGooglePlay,
///         entrypoint: 'lib/entrypoints/main_store_google_play.dart',
///         overlays: [gms],
///       ),
///       channel: PlayPublishTarget(packageName: '…'),
///       buildAab: true,
///     ),
///   ],
/// )
/// ```
///
/// Channels stay independently runnable (`oka run publish-play` still
/// works — the Steam/Xcode decoupling: build first, promote later), and
/// bare platform builds are unchanged (`oka build --platform android`).
///
/// Two composition-owned laws:
///
/// * **Defines have one writer.** [dartDefines] contributes nothing for
///   a delivery — [Variant.applyTo] (via [transformContext]) is the only
///   mechanism merging variant/overlay defines (plus the baked
///   [okaStoreDefine] identity) into the context, under the CLI defines.
///   The target-level define getter remains the general ADR-0014 surface
///   for plain targets.
/// * **The artifact format is composition-owned.** [buildAab]/
///   [artifactFormat] are delivery decisions; the CLI `--aab` flag
///   applies to bare platform builds and is ignored (with a loud
///   warning) when a delivery is dispatched.
///
/// Composition-time validation runs in [compile] — before any tool: the
/// variant's self-check, the channel's capability check (platform /
/// artifact format / overlay legality — the Gradle `variantFilter`
/// lesson as data), and name uniqueness (the dispatcher's existing law).
@immutable
class DeliveryTarget extends Target {
  /// Const constructor. [pipeline] is required — a delivery builds
  /// something. [variant]/[channel] are optional: a delivery may compose
  /// neither (a plain named build), one, or both (build + publish).
  const DeliveryTarget({
    required this.name,
    required this.pipeline,
    this.descriptionOverride,
    this.variant,
    this.channel,
    this.buildAab = false,
    this.artifactFormat,
  });

  /// Lowercase identifier for `oka run <name>` (e.g. `app-rustore`).
  @override
  final String name;

  /// Optional one-line description override; derived from the composition
  /// when omitted.
  final String? descriptionOverride;

  /// The artifact factory this delivery builds through (shared by
  /// reference — e.g. one [AndroidPipeline] serves every Android
  /// delivery).
  final PlatformPipeline pipeline;

  /// What compiles in (store key, entrypoint, defines, overlays). Null =
  /// store-neutral, defaults-only build.
  final Variant? variant;

  /// Where it publishes. Null = build-only delivery (the artifact stays
  /// in the build directory).
  final PublishTarget? channel;

  /// Whether this delivery produces an AAB instead of the platform
  /// default (Android: `--aab` semantics — Play's bundle format).
  final bool buildAab;

  /// Overrides the derived artifact-format id used for channel capability
  /// validation. Null → derived: `aab`/`apk` for Android (via [buildAab]),
  /// `web-dir` for web, otherwise the platform selector.
  final String? artifactFormat;

  /// The artifact-format id this delivery produces (derived or explicit
  /// override).
  String get effectiveArtifactFormat =>
      artifactFormat ??
      switch (pipeline.platform) {
        'android' => buildAab ? 'aab' : 'apk',
        'web' => 'web-dir',
        _ => pipeline.platform,
      };

  /// One-line description: the derived composition summary or the
  /// project-declared override.
  @override
  String get description =>
      descriptionOverride ??
      'build ${pipeline.platform} '
          '$effectiveArtifactFormat'
          '${variant == null ? '' : ' for ${variant!.key?.name ?? 'no store'}'}'
          '${channel == null ? '' : ' → ${channel!.name}'}';

  /// Compiles the delivery chain: the pipeline run (variant already
  /// applied to the context by [transformContext]), then the channel's
  /// full publish tail ([PublishTarget.compile] — staging, delivery
  /// gate, dry-run plan or real upload).
  ///
  /// Throws [ArgumentError] naming every composition violation before any
  /// step exists — the same no-execution-before-plan law as
  /// [Pipeline.validate].
  @override
  List<BuildStep> compile(BuildContext ctx) {
    final issues = validateComposition();
    if (issues.isNotEmpty) {
      throw ArgumentError(
        'delivery "$name" is not a valid composition:\n'
        '${issues.map((i) => '  - $i').join('\n')}',
      );
    }
    final channel = this.channel;
    return [
      RunPipelineStep(pipeline: pipeline),
      if (channel != null) ...channel.compile(ctx),
    ];
  }

  /// Applies the variant (and [buildAab]) to the context — the pure
  /// transform the dispatcher runs once so every step (pipeline steps and
  /// channel steps alike) sees the delivery's context.
  @override
  BuildContext transformContext(BuildContext ctx) {
    final variantCtx = variant?.applyTo(ctx) ?? ctx;
    return buildAab == ctx.buildAab
        ? variantCtx
        : variantCtx.copyWith(buildAab: buildAab);
  }

  /// No target-level defines — the variant is the single writer
  /// (ADR-0055). [Variant.applyTo] merges the variant/overlay defines
  /// (plus the baked [okaStoreDefine]) into the context **under** the
  /// CLI defines, so exactly one mechanism contributes a delivery's
  /// defines; `explainDetails` surfaces the same set for `oka explain`.
  ///
  /// The target-level define getter remains the general ADR-0014 surface
  /// for plain targets.
  @override
  Map<String, String> get dartDefines => const {};

  /// Composition validation (pure, empty = valid): variant self-check +
  /// channel capability check. The Gradle `variantFilter` lesson as
  /// typed data.
  List<String> validateComposition() {
    final issues = <String>[...?variant?.validate()];
    final channel = this.channel;
    if (channel != null) {
      issues.addAll(
        channel.validateDelivery(
          platform: pipeline.platform,
          artifactFormat: effectiveArtifactFormat,
          overlayNames: variant?.overlayNames ?? const {},
        ),
      );
    }
    return issues;
  }

  /// Explain lines: the composed matrix, readable before anything runs.
  @override
  List<String> explainDetails(BuildContext ctx) {
    final channel = this.channel;
    return [
      'pipeline: ${pipeline.platform} (by reference)',
      'artifact format: $effectiveArtifactFormat',
      ...?variant?.explainLines(),
      if (channel != null) ...[
        'channel: ${channel.name} → ${channel.endpoint}',
        if (channel.dryRun) 'channel posture: dry run',
      ],
    ];
  }

  /// Debug string: name plus the composed axes.
  @override
  String toString() =>
      'Delivery($name: ${pipeline.platform}/$effectiveArtifactFormat'
      '${variant == null ? '' : ' + ${variant!.key?.name ?? 'no store'}'}'
      '${channel == null ? '' : ' → ${channel!.name}'})';
}

/// The delivery alias — the ADR-0055 word for the named build+publish
/// composition. `Delivery(name: …, pipeline: …)` reads as the concept;
/// [DeliveryTarget] is the contract behind it.
typedef Delivery = DeliveryTarget;
