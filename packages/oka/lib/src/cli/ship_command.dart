import 'package:oka_dart_kernel/ship_cli.dart';

import 'kernel_stack.dart';

/// `oka ship` — derive a patch from the working tree and the channel
/// (ADR-0037 §1).
///
/// The published executable calls [runShipCli]. Signing-key generation and
/// snapshots that already use Flutter or `dart compile kernel` need no
/// kernel compiler. A unit delta does, and that compiler stays in an oka
/// checkout named by `OKA_KERNEL_ROOT`.
class ShipCommand {
  Future<void> run(List<String> args) => runPublishedOrCheckout(
    runner: shipRunner,
    args: args,
    inProcess: runShipCli,
    unsetHint: 'Unset it to use the ship command built into this oka.',
  );
}
