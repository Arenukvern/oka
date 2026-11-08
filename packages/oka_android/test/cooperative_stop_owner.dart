import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Test stand-in for an `oka dev android` owning process.
Future<void> main(List<String> args) async {
  final root = args[0];
  final controlPort = int.parse(args[1]);
  final discoveryDir = Directory('$root/.flutter_mcp');
  await discoveryDir.create(recursive: true);
  final session = {
    'schema': 1,
    'runner': 'cooperative-stop-owner',
    'vm_service_uri': 'http://127.0.0.1:1/x',
    'control_port': controlPort,
    'device_id': 'emu',
    'pid': pid,
    'started_at': DateTime.now().toUtc().toIso8601String(),
  };
  await File('${discoveryDir.path}/runner-session.json').writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(session)}\n',
  );
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.trim() == 'stop') {
      unawaited(_clearAndExit(root));
    }
  });
  await Completer<void>().future.timeout(const Duration(days: 1));
}

Future<void> _clearAndExit(String root) async {
  try {
    await File('$root/.flutter_mcp/runner-session.json').delete();
  } on Object {
    // Already gone.
  }
  exit(0);
}
