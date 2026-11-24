/// The `oka live` command (ADR-0036 Tier 2).
///
/// `oka` calls [runLiveCli] directly. `verify` needs no kernel compiler.
/// `patch` and `watch` do, and that compiler stays in the checkout.
library;

export 'src/live/live_cli.dart';
