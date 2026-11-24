import 'package:oka_dart_kernel/live_cli.dart';

import 'kernel_stack.dart';

/// `oka live` — the live-update verbs (ADR-0036 Tier 2).
///
/// The published executable calls [runLiveCli]. `verify` needs no kernel
/// compiler. `patch` and `watch` do, and that compiler stays in an oka
/// checkout named by `OKA_KERNEL_ROOT`.
class LiveCommand {
  Future<void> run(List<String> args) => runPublishedOrCheckout(
    runner: liveRunner,
    args: args,
    inProcess: runLiveCli,
    unsetHint: 'Unset it to use the live command built into this oka.',
  );
}
