import 'kernel_stack.dart';

/// `oka ship` — delegates to the experimental ship runner
/// (`oka_dart_kernel/tool/oka_ship.dart`, ADR-0037 §1), same posture as
/// `oka live` and `oka run dev` (the live stack is `publish_to: none`, so
/// the published CLI takes no non-publishable dependency). Derives the
/// patch from the working tree and the channel state — the developer
/// declares units once and runs one command.
class ShipCommand {
  Future<void> run(List<String> args) => delegateToKernelStack(
        runner: 'packages/oka_dart_kernel/tool/oka_ship.dart',
        args: args,
        missingMessage: 'oka ship: the experimental live-update stack is '
            'not available.\nPoint OKA_KERNEL_ROOT at a checkout with '
            'packages/oka_dart_kernel (see docs/guides/live_update.mdx).',
      );
}
