import 'dart:io';
import 'package:oka/src/build/plugin_discovery.dart';

void main() async {
  final path = '${Platform.environment['HOME']}/xs/vitamins_quiz_bot/vitamin_shippic_app';
  final d = PluginDiscovery(verbose: true);
  final r = await d.discover(path);
  print('plugins total: ${r.plugins.length}');
  print('android: ${r.androidPlugins.length}');
  print('unsupported: ${r.unsupported.length}');
  for (final p in r.androidPlugins) {
    print('  ${p.name} class=${p.qualifiedClass} unsupported=${p.unsupportedNative} reason=${p.unsupportedReason ?? "-"}');
  }
  try {
    d.ensureSupported(r, strict: true);
    print('ensureSupported: OK');
  } catch (e) {
    print('ensureSupported: FAIL\n$e');
  }
}
