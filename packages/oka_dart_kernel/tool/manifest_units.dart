/// Prints one line per loading unit in a gen_snapshot manifest:
/// `<id> <path> <comma-separated library URIs>`. Pure dart:{io,convert} —
/// runs under any SDK (used inside containers too).
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final manifest =
      jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>;
  for (final unit in manifest['loadingUnits'] as List) {
    final u = unit as Map<String, dynamic>;
    final libs = (u['libraries'] as List).cast<String>();
    stdout.writeln('${u['id']} ${u['path']} ${libs.join(',')}');
  }
}
