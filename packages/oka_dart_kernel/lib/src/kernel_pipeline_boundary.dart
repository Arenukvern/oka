import 'dart:io';

/// What a published oka says when a verb needs the kernel delta compiler.
///
/// The compiler imports `package:kernel` and is not in the pub tarball.
/// Building or running it needs an oka checkout plus a Dart SDK checkout.
String missingKernelPipelineMessage(String command) =>
    '$command needs the kernel delta compiler, which is not in this oka '
    'binary.\n'
    'Set OKA_KERNEL_ROOT to an oka checkout that contains\n'
    'packages/oka_dart_kernel/tool/pipeline_packages_config.sh\n'
    'and provision a Dart SDK checkout at ~/.oka/dart-sdks\n'
    '(override OKA_SDK_CHECKOUT).';

/// True when [kernelRoot] is an oka_dart_kernel package root whose
/// unpublished pipeline scripts are on disk.
bool kernelPipelineScriptsPresent(String kernelRoot) =>
    File('$kernelRoot/tool/pipeline_packages_config.sh').existsSync() &&
    File('$kernelRoot/tool/build_pipeline_exe.sh').existsSync();
