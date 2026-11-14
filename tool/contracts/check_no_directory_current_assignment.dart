import 'dart:io';

import 'package:oka_core/oka_core.dart';

Never _fail(String message) {
  stderr.writeln('check_no_directory_current_assignment: $message');
  exit(1);
}

final _assignmentPattern = RegExp(r'Directory\.current\s*=');

void main() {
  final root = findOkaWorkspaceRoot();
  final offenders = <String>[];

  for (final dir in [
    Directory('$root/test'),
    ...Directory('$root/packages')
        .listSync()
        .whereType<Directory>()
        .map((d) => Directory('${d.path}/test'))
        .where((d) => d.existsSync()),
  ]) {
    for (final file in dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_assignmentPattern.hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
  }

  if (offenders.isNotEmpty) {
    _fail(
      'tests must not assign Directory.current (process-global across isolates):\n'
      '${offenders.join('\n')}',
    );
  }
  stdout.writeln('check_no_directory_current_assignment: ok');
}
