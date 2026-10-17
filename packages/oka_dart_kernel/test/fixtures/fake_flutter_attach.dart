import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  for (var i = 0; i < 4500; i++) {
    stdout.writeln('startup noise $i');
  }
  stdout.writeln('Reloaded 0 of 1 libraries');
  stdout.writeln('Flutter run key commands.');
  await for (final command
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (command == 'r') stdout.writeln('Reloaded 1 of 1 libraries');
    if (command == 'd') {
      stdout.writeln('Detached');
      return;
    }
  }
}
