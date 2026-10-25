import 'kernel_stack.dart';

/// Checkout-backed iteration lane; conventional tests remain acceptance.
class VerifyCommand {
  Future<void> run(List<String> args) => delegateToKernelStack(
    runner: 'packages/oka_verify/bin/oka_verify.dart',
    args: args,
    missingMessage:
        'oka verify: the internal verification package is '
        'not available. Set OKA_KERNEL_ROOT to an Oka checkout containing '
        'packages/oka_verify and run dart pub get --no-example there.',
  );
}
