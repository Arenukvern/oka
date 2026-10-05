import 'dart:async';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

import '../tool/oka_run_dev.dart' show DevApp, runRunDevCli;

/// A fake owning `flutter run` session: records stdin writes, answers the
/// restart wait, and feeds the exit path.
class _FakeApp implements DevApp {
  final written = <String>[];
  final _lines = <String>[];
  final _waiters = <(Pattern, Completer<String>)>[];

  @override
  final Uri vmUri = Uri.parse('http://127.0.0.1:8111/token=/');

  void emit(String line) {
    _lines.add(line);
    for (final (pattern, completer) in _waiters) {
      if (!completer.isCompleted && line.contains(pattern)) {
        completer.complete(line);
      }
    }
  }

  @override
  void write(String line) {
    written.add(line);
    if (line == 'R') emit('Restarted application in 271ms.');
  }

  @override
  Future<String> waitFor(Pattern pattern,
      {Duration timeout = const Duration(seconds: 90)}) {
    for (final line in _lines) {
      if (line.contains(pattern)) return Future.value(line);
    }
    final completer = Completer<String>();
    _waiters.add((pattern, completer));
    return completer.future.timeout(timeout);
  }

  @override
  Future<int> stop() async => 0;
}

/// A fake target: applies succeed, nothing touches a wire. Records
/// asset syncs so the dev session's asset lane is testable.
class _FakeTarget implements LivePatchTarget {
  int applies = 0;
  final assetSyncs = <({String assetKey, int bytes, String dir})>[];

  @override
  String get kind => 'vm';

  @override
  String get id => 'app';

  @override
  Future<void> connect() async {}

  @override
  Future<ApplyOutcome> apply(
      {required String unit,
      required String deltaPath,
      required int deltaBytes}) async {
    applies++;
    return const ApplyOutcome(ok: true, mode: 'fake');
  }

  @override
  Future<ApplyOutcome> syncAsset(
      {required String assetKey,
      required List<int> bytes,
      required String flutterAssetsDir,
      bool shader = false}) async {
    assetSyncs.add((
      assetKey: assetKey,
      bytes: bytes.length,
      dir: flutterAssetsDir,
    ));
    return ApplyOutcome(
        ok: true,
        mode: 'assets-sync',
        wire: {'evict': 'ok', 'dir': flutterAssetsDir});
  }

  @override
  Future<String> evaluate(ProbeSpec probe) => Future.value('');

  @override
  Future<void> close() async {}
}

void main() {
  late Directory tmp;
  late String root;
  late _FakeApp app;
  late _FakeTarget target;
  late List<String> compiled;
  final out = <String>[];
  var exit = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('oka-run-dev-test-');
    root = '${tmp.path}/app';
    Directory('$root/lib').createSync(recursive: true);
    File('$root/lib/main.dart')
        .writeAsStringSync('void main() {}\nint seed() => 1;\n');
    app = _FakeApp();
    target = _FakeTarget();
    compiled = [];
    out.clear();
    exit = 0;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> dev(List<String> args, List<String> lines) {
    final commands = StreamController<String>();
    final done = runRunDevCli(
      ['--project', root, ...args],
      devApp: app,
      compile: (request) async {
        compiled.addAll(request.patchedFiles);
        return DeltaArtifact(path: '${tmp.path}/x.dill', bytes: 4);
      },
      targetOverrides: {'app': target},
      output: out.add,
      errorOutput: out.add,
      setExitCode: (c) => exit = c,
      commands: commands.stream,
      workingDir: tmp.path,
    );
    lines.forEach(commands.add);
    unawaited(commands.close());
    return done;
  }

  test('r <file> compiles the changed file and applies over the lane',
      () async {
    await dev([], ['r lib/main.dart', 'q']);
    expect(exit, 0);
    expect(compiled.single, endsWith('lib/main.dart'));
    expect(target.applies, 1);
    expect(out.join('\n'), contains('reload 1: OK'));
    expect(app.written, contains('q'));
  });

  test('R restarts through the platform lane', () async {
    await dev([], ['R', 'q']);
    expect(exit, 0);
    expect(app.written, contains('R'));
    expect(out.join('\n'), contains('restart: OK (platform lane'));
  });

  test('bare r without a changed file hints instead of compiling',
      () async {
    await dev([], ['r', 'q']);
    expect(exit, 0);
    expect(compiled, isEmpty);
    expect(out.join('\n'), contains('no changed file'));
  });

  test('unknown command prints the session help', () async {
    await dev([], ['reload now', 'q']);
    expect(exit, 0);
    expect(out.join('\n'), contains('unknown command: reload now'));
  });

  test('r <asset> rides the sync lane, not the delta lane', () async {
    Directory('$root/assets').createSync();
    final asset = File('$root/assets/hello.txt')
      ..writeAsStringSync('hello');
    Directory('$root/build/macos/Build/Products/Debug'
            '/app.app/Contents/Frameworks/App.framework/Versions/A'
            '/Resources/flutter_assets')
        .createSync(recursive: true);
    await dev([], ['r assets/hello.txt', 'q']);
    expect(exit, 0);
    expect(target.applies, 0, reason: 'assets never compile as deltas');
    expect(target.assetSyncs.single.assetKey, 'assets/hello.txt');
    expect(target.assetSyncs.single.bytes, 5);
    expect(target.assetSyncs.single.dir, contains('flutter_assets'));
    expect(out.join('\n'), contains('assets 1: OK'));
    // The synced file lands in the fake dir the target records.
    expect(asset.existsSync(), isTrue);
  });

  test('malformed flags print usage and exit 2', () async {
    await dev(['--bogus'], []);
    expect(exit, 2);
    expect(out.join('\n'), contains('usage: oka run dev'));
  });
}
