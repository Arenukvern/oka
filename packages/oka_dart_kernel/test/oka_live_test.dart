/// Behavior tests for the `oka live` runner (ADR-0036 Tier 2): argument
/// parsing, verb dispatch through the declared catalog, receipt output,
/// and exit codes — with in-memory targets, no real wires.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

import '../tool/oka_live.dart' show runLiveCli;

class _FakeTarget implements LivePatchTarget {
  _FakeTarget(this.id, {this.applyValues = const {}});
  @override
  final String id;
  @override
  final String kind = 'fake';
  final Map<String, String> values = {'label': 'alpha-g4a'};
  final Map<String, String> applyValues;
  int applied = 0;

  @override
  Future<void> connect() async {}

  @override
  Future<ApplyOutcome> apply({
    required String unit,
    required String deltaPath,
    required int deltaBytes,
  }) async {
    applied++;
    values.addAll(applyValues);
    return const ApplyOutcome(ok: true, mode: 'fake-apply');
  }

  @override
  Future<String> evaluate(ProbeSpec probe) async => values[probe.expression]!;

  @override
  Future<void> close() async {}
}

void main() {
  late Directory root;
  late String specPath;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('oka_live_cli_test');
    File('${root.path}/unit.dart').writeAsStringSync("const label = 'x';\n");
    specPath = '${root.path}/spec.json';
    File(specPath).writeAsStringSync('''
{
  "revision": "rev-b", "unit": "alpha",
  "patches": [{"file": "unit.dart", "find": "x", "replace": "y"}],
  "targets": [{"kind": "fake", "id": "t1"}],
  "probes": [{"expression": "label"}]
}''');
  });

  tearDown(() => root.delete(recursive: true));

  test('malformed invocation: usage on stderr, exit 2', () async {
    final err = <String>[];
    final codes = <int>[];
    await runLiveCli(const ['nope'],
        errorOutput: err.add, setExitCode: codes.add);
    expect(codes, [2]);
    expect(err.join(), contains('usage: oka live'));
  });

  test('missing spec: exit 2 with the path', () async {
    final err = <String>[];
    final codes = <int>[];
    await runLiveCli(const ['verify', '--spec', '/nope/none.json'],
        errorOutput: err.add, setExitCode: codes.add);
    expect(codes, [2]);
    expect(err.join(), contains('/nope/none.json'));
  });

  test('verify verb: probes captured, JSON receipt, exit 0', () async {
    final out = <String>[];
    final codes = <int>[];
    await runLiveCli(
      ['verify', '--spec', specPath, '--project', root.path, '--json'],
      compiler: (request) => Future.value(
          const DeltaArtifact(path: 'fake.dill', bytes: 1)),
      targetOverrides: {'t1': _FakeTarget('t1')},
      output: out.add,
      setExitCode: codes.add,
    );
    expect(codes, [0]);
    final receipt =
        (jsonDecode(out.join()) as Map).cast<String, dynamic>();
    expect(receipt['ok'], isTrue);
    expect((receipt['targets'] as List).length, 1);
  });

  test('patch verb: applies through the catalog, exit 0', () async {
    final out = <String>[];
    final codes = <int>[];
    final fake = _FakeTarget('t1', applyValues: {'label': 'alpha-g4b'});
    await runLiveCli(
      ['patch', '--spec', specPath, '--project', root.path],
      compiler: (request) => Future.value(
          const DeltaArtifact(path: 'fake.dill', bytes: 1)),
      targetOverrides: {'t1': fake},
      output: out.add,
      setExitCode: codes.add,
    );
    expect(codes, [0]);
    expect(fake.applied, 1);
    expect(out.join(), contains('live patch OK'));
    expect(out.join(), contains('label'));
  });
}
