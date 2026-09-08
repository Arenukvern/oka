/// Typed pipeline events (ADR-0007): emitted by the runner and steps so CLI,
/// TUI and CI consumers observe build progress structurally instead of
/// parsing stdout.
library;

/// Base class — all events carry a wall-clock timestamp.
abstract class PipelineEvent {
  /// Wall-clock time the event was created (constructor capture).
  PipelineEvent() : timestamp = DateTime.now();

  /// When the event happened.
  final DateTime timestamp;
}

/// A step began executing.
class StepStarted extends PipelineEvent {
  /// [step] is the step name.
  StepStarted(this.step);

  /// Name of the step that started.
  final String step;
}

/// A step finished.
class StepFinished extends PipelineEvent {
  /// Wraps the step name, outcome, error text, and wall-clock duration.
  StepFinished(
    this.step, {
    required this.ok,
    required this.error,
    required this.duration,
  });

  /// Name of the step that finished.
  final String step;

  /// `true` when the step succeeded.
  final bool ok;

  /// Failure text (null on success).
  final String? error;

  /// How long the step ran.
  final Duration duration;
}

/// A step was served from the incremental cache.
class CacheEvent extends PipelineEvent {
  /// Wraps the step name and whether the cache was hit.
  CacheEvent(this.step, {required this.hit});

  /// Name of the cached step.
  final String step;

  /// `true` when served from cache (false = a miss/invalidation).
  final bool hit;
}

/// A warning that does not fail the build but demands attention.
class BuildWarning extends PipelineEvent {
  /// Wraps the message and the optional step it originated from.
  BuildWarning(this.message, {this.step});

  /// The warning text.
  final String message;

  /// Step the warning came from (null = run-level).
  final String? step;
}

/// Free-form progress message.
class PipelineLog extends PipelineEvent {
  /// Wraps the message and the optional step it originated from.
  PipelineLog(this.message, {this.step});

  /// The progress text.
  final String message;

  /// Step that logged this (null = run-level).
  final String? step;
}
