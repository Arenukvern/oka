import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _stdinQuitOwner = r'''
#!/bin/sh
set -e
ROOT="$1"
mkdir -p "$ROOT/.flutter_mcp"
cat > "$ROOT/.flutter_mcp/runner-session.json" <<'JSON'
{"schema":1,"runner":"fake","vm_service_uri":"http://127.0.0.1:1/x","control_port":0,"device_id":"emu","pid":1,"started_at":"2026-01-01T00:00:00.000Z"}
JSON
while read -r line; do
  case "$line" in quit|exit)
    rm -f "$ROOT/.flutter_mcp/runner-session.json"
    exit 0
    ;;
  esac
done
''';

void main() {
  test('stopOkaDevAndroidSession splits stdin written vs TCP ack', () async {
    final root = await Directory.systemTemp.createTemp('oka_stop_');
    addTearDown(() => root.delete(recursive: true));
    final script = File(p.join(root.path, 'owner.sh'))
      ..writeAsStringSync(_stdinQuitOwner);
    await Process.run('chmod', ['+x', script.path]);
    final process = await Process.start(
      script.path,
      [root.path],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final report = await stopOkaDevAndroidSession(
      owningProcess: process,
      projectPath: root.path,
      controlPort: 0,
      quitTimeout: const Duration(seconds: 10),
    );
    expect(report.stdinQuitWritten, isTrue);
    expect(report.controlQuitAcknowledged, isFalse);
    expect(report.controlQuitSent, isFalse);
    expect(report.runnerSessionCleared, isTrue);
    expect(report.processExitCode, 0);
    expect(report.disposition, DevSessionStopDisposition.cooperative);
    expect(report.ok, isTrue);
  });
}
