import 'dart:convert';
import 'dart:io';

/// Minimal `oka run dev` transcript for owned-session gate tests.
Future<void> main(List<String> args) async {
  final hang = args.contains('--hang-on-quit');
  stdout.writeln('dev: ready — commands: r [file] | R | q');
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final t = line.trim();
    if (t == 'q') {
      if (hang) {
        await Future<void>.delayed(const Duration(hours: 1));
      }
      exit(0);
    }
    if (t == 'R') {
      stdout.writeln('Restarted application in 1ms.');
      stdout.writeln('restart: OK (platform lane, 1ms)');
    }
    if (t.startsWith('r')) {
      stdout.writeln('reload 1: OK');
    }
  }
}
