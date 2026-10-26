import 'package:meta/meta.dart';

/// Outcome of waiting for an owned group to finish after stop.
@immutable
sealed class SettlementResult {
  const SettlementResult();
}

/// Group is gone or target exit status is known.
@immutable
final class SettlementSettled extends SettlementResult {
  const SettlementSettled({this.exitCode, this.signal});

  /// Exit code when known (leader or target per backend contract).
  final int? exitCode;

  /// Signal number when process did not exit normally.
  final int? signal;
}

/// Wire and policy reasons for [SettlementUnsettled] (p1 contract
/// `unsettled:<reason>` suffixes).
abstract final class UnsettledReason {
  /// Host closed the control channel without `settle` (host-death guard).
  static const hostEof = 'host-eof';
}

/// Stop could not prove settlement (observation fault, timeout, hook hung, …).
@immutable
final class SettlementUnsettled extends SettlementResult {
  const SettlementUnsettled(this.reason);

  /// Contract reason token (e.g. [UnsettledReason.hostEof]) or host message.
  final String reason;
}
