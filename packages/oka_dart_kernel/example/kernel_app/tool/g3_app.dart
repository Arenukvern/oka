// G3 live-reload subject: prints the tiny unit's label on an interval so an
// out-of-process `reloadSources(kernelBytes: delta)` becomes observable
// without a restart.
import 'dart:io';
import '../lib/units/tiny.dart' as tiny;

Future<void> main() async {
  stdout.writeln('g3: up with ${tiny.tinyLabel()}');
  for (var i = 0; i < 240; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    stdout.writeln('g3: ${tiny.tinyLabel()}');
  }
  stdout.writeln('g3: exiting');
}
