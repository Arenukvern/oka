/// Typed pipeline events (ADR-0007): emitted by the runner and steps so CLI,
/// TUI and CI consumers observe build progress structurally instead of
/// parsing stdout.
library;

/// Base class — all events carry a wall-clock timestamp.
abstract class PipelineEvent {
  final DateTime timestamp;

  PipelineEvent() : timestamp = DateTime.now();
}

/// A step began executing.
class StepStarted extends PipelineEvent {
  final String step;

  StepStarted(this.step);
}

/// A step finished.
class StepFinished extends PipelineEvent {
  final String step;
  final bool ok;
  final String? error;
  final Duration duration;

  StepFinished(this.step, this.ok, this.error, this.duration);
}

/// A step was served from the incremental cache.
class CacheEvent extends PipelineEvent {
  final String step;
  final bool hit;

  CacheEvent(this.step, this.hit);
}

/// A warning that does not fail the build but demands attention.
class BuildWarning extends PipelineEvent {
  final String message;
  final String? step;

  BuildWarning(this.message, {this.step});
}

/// Free-form progress message.
class PipelineLog extends PipelineEvent {
  final String message;
  final String? step;

  PipelineLog(this.message, {this.step});
}
