import 'package:meta/meta.dart';

import 'process_identity_token.dart';
import 'settlement.dart';

/// Structured result of a stop attempt on an owned session.
@immutable
final class StopReceipt {
  const StopReceipt({
    required this.identity,
    required this.settlement,
    this.failedStopEvidence,
  });

  final ProcessIdentityToken identity;
  final SettlementResult settlement;

  /// Optional ADR-0046-style recovery evidence when stop missed deadline.
  final String? failedStopEvidence;

  bool get isSettled => settlement is SettlementSettled;
}
