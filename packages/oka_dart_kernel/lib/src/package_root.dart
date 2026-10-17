/// Locate the oka_dart_kernel package checkout from the consumer's
/// package graph (no OKA_ROOT / foreign `--packages=` jail).
library;

import 'dart:io';
import 'dart:isolate';

/// Absolute path of the oka_dart_kernel package root (directory that
/// contains `tool/oka_live_watch.dart`).
///
/// Resolves `package:oka_dart_kernel/…` through the running isolate's
/// package config — the consumer must depend on this package (path or
/// hosted) so the URI resolves.
Future<String> resolveOkaDartKernelRoot() async {
  final resolved = await Isolate.resolvePackageUri(
    Uri.parse('package:oka_dart_kernel/oka_dart_kernel.dart'),
  );
  if (resolved == null || !resolved.isScheme('file')) {
    throw StateError(
      'oka_dart_kernel_not_in_package_config — add a path/hosted '
      'dependency so tools resolve without OKA_ROOT package_config',
    );
  }
  return File.fromUri(resolved).parent.parent.path;
}
