import 'kernel_stack.dart';

/// `oka live` — delegates to the experimental live-update runner
/// (`oka_dart_kernel/tool/oka_live.dart`, ADR-0036 Tier 2), same posture
/// as `oka ship` and `oka run dev` (the live stack is `publish_to: none`,
/// so the published CLI takes no non-publishable dependency).
class LiveCommand {
  Future<void> run(List<String> args) => delegateToKernelStack(
        runner: 'packages/oka_dart_kernel/tool/oka_live.dart',
        args: args,
        missingMessage: 'oka live: the experimental live-update stack is '
            'not available.\nPoint OKA_KERNEL_ROOT at a checkout with '
            'packages/oka_dart_kernel (see docs/guides/live_update.mdx).',
      );
}
