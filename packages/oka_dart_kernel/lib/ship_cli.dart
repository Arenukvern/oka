/// The `oka ship` command (ADR-0037 §1).
///
/// `oka` calls [runShipCli] directly. Signing-key generation and snapshots
/// that use Flutter or `dart compile kernel` need no kernel compiler.
/// A unit delta does, and that compiler stays in the checkout.
library;

export 'src/ship/ship_cli.dart';
