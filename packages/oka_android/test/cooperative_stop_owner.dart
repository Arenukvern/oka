import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Test stand-in for an `oka dev android` owning process.
///
/// Publishes runner-session.json with the same temp+rename atomic write as
/// [FileDevDiscoveryStore.writeRunnerSession] (no torn reads under poll).
Future<void> main(List<String> args) async {
  final root = args[0];
  final controlPort = int.parse(args[1]);
  await _writeRunnerSessionAtomic(
    root,
    controlPort: controlPort,
    deviceId: 'emu',
    processPid: pid,
  );
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.trim() == 'stop') {
      unawaited(_clearAndExit(root));
    }
  });
  await Completer<void>().future.timeout(const Duration(days: 1));
}

Future<void> _writeRunnerSessionAtomic(
  String projectPath, {
  required int controlPort,
  required String deviceId,
  required int processPid,
}) async {
  final dir = Directory('$projectPath/.flutter_mcp');
  await dir.create(recursive: true);
  final file = File('${dir.path}/runner-session.json');
  final temp = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  final body = const JsonEncoder.withIndent('  ').convert({
    'schema': 1,
    'runner': 'cooperative-stop-owner',
    'vm_service_uri': 'http://127.0.0.1:1/x',
    'control_port': controlPort,
    'device_id': deviceId,
    'pid': processPid,
    'started_at': DateTime.now().toUtc().toIso8601String(),
  });
  await temp.writeAsString('$body\n', flush: true);
  await temp.rename(file.path);
}

Future<void> _clearAndExit(String root) async {
  try {
    await File('$root/.flutter_mcp/runner-session.json').delete();
  } on FileSystemException {
    // Already absent.
  }
  exit(0);
}
