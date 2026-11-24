import 'package:oka_verify/oka_verify_cli.dart' as verify;

import 'kernel_stack.dart';

/// `oka verify` — the fast Dart lane (ADR-0048).
///
/// The published executable calls the `oka_verify` library. Conventional
/// `dart test` remains the acceptance oracle. Widget suites are refused.
class VerifyCommand {
  Future<void> run(List<String> args) => runPublishedOrCheckout(
    runner: verifyRunner,
    args: args,
    inProcess: verify.main,
    unsetHint: 'Unset it to use the verify lane built into this oka.',
  );
}
