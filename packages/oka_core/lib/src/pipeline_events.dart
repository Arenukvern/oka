/// Typed pipeline events (ADR-0007): emitted by the runner and steps so CLI,
/// TUI and CI consumers observe build progress structurally instead of
/// parsing stdout.
library;

/// Base class — all events carry a wall-clock timestamp.
abstract class PipelineEvent {

  PipelineEvent() : timestamp = DateTime.now();
  final DateTime timestamp;
}

/// A step began executing.
class StepStarted extends PipelineEvent {

  StepStarted(this.step);
  final String step;
}

/// A step finished.
class StepFinished extends PipelineEvent {

  StepFinished(
    this.step, {
    required this.ok,
    required this.error,
    required this.duration,
  });
  final String step;
  final bool ok;
  final String? error;
  final Duration duration;
}

/// A step was served from the incremental cache.
class CacheEvent extends PipelineEvent {

  CacheEvent(this.step, {required this.hit});
  final String step;
  final bool hit;
}

/// A warning that does not fail the build but demands attention.
class BuildWarning extends PipelineEvent {

  BuildWarning(this.message, {this.step});
  final String message;
  final String? step;
}

/// Free-form progress message.
class PipelineLog extends PipelineEvent {

  PipelineLog(this.message, {this.step});
  final String message;
  final String? step;
}
