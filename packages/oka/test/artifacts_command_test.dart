import 'dart:convert';
import 'dart:io';

import 'package:oka/src/cli/artifacts_command.dart';
import 'package:oka_artifacts/oka_artifacts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `oka artifacts` wiring (ADR-0043): put → status → materialize →
/// verify against a temp store root; the real ~/.oka is never touched.
void main() {
  late Directory temp;
  late Directory root;
  final output = <String>[];
  final errors = <String>[];
  final exitCodes = <int>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_artifacts_cli_');
    root = Directory(p.join(temp.path, 'artifacts'));
    output.clear();
    errors.clear();
    exitCodes.clear();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  ArtifactsCommand command() => ArtifactsCommand(
        output: output.add,
        errorOutput: errors.add,
        setExitCode: exitCodes.add,
        store: ArtifactStore(root: root),
      );

  File artifactWith(final String tag) => File(p.join(temp.path, '$tag.bin'))
    ..writeAsBytesSync(List.generate(4096, (final i) => tag.length + i % 251));

  test('put → status → materialize round-trips the head bytes', () async {
    final artifact = artifactWith('a');

    await command().run(['put', artifact.path, '--name', 'demo', '--json']);
    final receipt =
        jsonDecode(output.join('\n')) as Map<String, Object?>;
    expect(receipt['kind'], 'snapshot');
    output.clear();

    await command().run(['status', 'demo', '--json']);
    final status = jsonDecode(output.join('\n')) as Map<String, Object?>;
    expect(status['snapshots'], 1);
    output.clear();

    final out = p.join(temp.path, 'restored.bin');
    await command().run(['materialize', 'demo', '-o', out]);
    expect(File(out).readAsBytesSync(), artifact.readAsBytesSync());
    output.clear();

    await command().run(['verify', 'demo', '--json']);
    final verify = jsonDecode(output.join('\n')) as Map<String, Object?>;
    expect(verify['ok'], isTrue);
    expect(exitCodes, isEmpty);
  });

  test('identical put reports unchanged and writes no second blob', () async {
    final artifact = artifactWith('same');
    await command().run(['put', artifact.path, '--name', 'dup']);
    output.clear();
    await command().run(['put', artifact.path, '--name', 'dup', '--json']);
    final receipt =
        jsonDecode(output.join('\n')) as Map<String, Object?>;
    expect(receipt['unchanged'], isTrue);
  });

  test('missing chain names the problem and exits 1', () async {
    await command().run(['verify', 'never-recorded', '--json']);
    expect(exitCodes, [1]);
    final combined = '${output.join()}\n${errors.join()}';
    expect(combined, contains('no artifact chain'));
  });

  test('--pointer writes a parseable provenance manifest', () async {
    final artifact = artifactWith('p');
    final pointerPath = p.join(temp.path, 'demo.json');
    await command().run([
      'put',
      artifact.path,
      '--name',
      'demo',
      '--pointer',
      pointerPath,
      '--entrypoint',
      'bin/app.dart',
      '--inputs',
      'abc123',
    ]);
    final pointer = ArtifactPointer.fromJsonString(
      File(pointerPath).readAsStringSync(),
    );
    expect(pointer.name, 'demo');
    expect(pointer.entrypoint, 'bin/app.dart');
    expect(pointer.inputsHash, 'abc123');
    expect(pointer.backend, 'local');
  });

  test('unknown subcommand exits 2 naming the command', () async {
    await command().run(['frobnicate']);
    expect(exitCodes, [2]);
    expect(errors.join(), contains('frobnicate'));
  });
}
