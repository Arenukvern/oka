import 'package:meta/meta.dart';

/// Shared wall-clock budget for readonly observations during stop/teardown
/// ([ADR-0046](https://github.com/Arenukvern/oka/blob/main/docs/decisions/0046-failed-deadline-teardown-receipts)).
@immutable
final class ObservationBudget {
  const ObservationBudget(this.duration);

  static const ObservationBudget defaults = ObservationBudget(
    Duration(seconds: 2),
  );

  final Duration duration;

  void validatePositive() {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'must be positive');
    }
  }
}
