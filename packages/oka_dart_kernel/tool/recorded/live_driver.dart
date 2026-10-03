/// Live-swap driver for the Linux experiment: loads the alpha unit, then
/// blocks on a filesystem marker before loading beta — so the operator can
/// replace beta's unit ELF *while the process is running* and we can see
/// whether the VM loads the replaced bytes (and whether it verifies them).
import 'dart:io';
import 'package:oka_patch_spike/registry.dart';

Future<void> main() async {
  stdout.writeln('driver: core up');
  stdout.writeln('registry alpha: ${await loadAlpha()}');
  final marker = File(Platform.environment['SPIKE_MARKER'] ?? '/tmp/spike/go_swap');
  stdout.writeln('driver: waiting for marker ${marker.path}');
  while (!marker.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  stdout.writeln('driver: marker seen, loading beta NOW');
  stdout.writeln('beta (loadLibrary): ${await loadBeta()}');
  stdout.writeln('driver: done');
}
