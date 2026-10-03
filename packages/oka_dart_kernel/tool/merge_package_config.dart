/// Merges a pub-solved shim package_config with the pinned-checkout kernel
/// stack into the pipeline package_config used by gate scripts. Pure
/// dart:{io,convert} — runs inside containers (no python there).
///
/// usage: merge_package_config.dart <shim-config> <out-config> <extra.json>
///
/// The extra file is a JSON array of package entries (checkout-local kernel
/// stack + oka_dart_kernel). The shim's own entry is dropped.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln('usage: merge_package_config.dart <shim> <out> <extra>');
    exitCode = 2;
    return;
  }
  final shim = jsonDecode(File(args[0]).readAsStringSync())
      as Map<String, dynamic>;
  final extra = jsonDecode(File(args[2]).readAsStringSync()) as List<dynamic>;
  // Extra entries (checkout kernel stack + oka_dart_kernel) win over the
  // shim's solved versions: the SDK checkout vendors some packages
  // (package_config, meta, ...) that pub also solves, and duplicate names in
  // a package_config resolve implementation-defined. Checkout must win.
  final extraNames = extra.cast<Map<String, dynamic>>().map((e) => e['name']).toSet();
  final entries = [
    ...(shim['packages'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((e) => e['name'] != 'depshim' && !extraNames.contains(e['name'])),
    ...extra.cast<Map<String, dynamic>>(),
  ];
  File(args[1]).writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert({
      'configVersion': 2,
      'packages': entries,
    }),
  );
}
