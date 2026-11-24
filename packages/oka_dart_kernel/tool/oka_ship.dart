import 'dart:io';

import 'package:oka_dart_kernel/ship_cli.dart';

export 'package:oka_dart_kernel/ship_cli.dart';

/// Checkout runner. The published `oka` executable calls [runShipCli]
/// in-process and does not use this script. `OKA_KERNEL_ROOT` points at
/// a checkout so someone working on the session can run this file instead.
Future<void> main(List<String> args) => runShipCli(
  args,
  kernelRoot: File.fromUri(Platform.script).parent.parent.path,
);
