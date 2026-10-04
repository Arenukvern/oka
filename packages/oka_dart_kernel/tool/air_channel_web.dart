/// Air channel — web verify rung (ADR-0037 G-AC7; ADR-0031 gates 2–4 on
/// the generated path): the channel is produced by the invisible ship
/// from the app's working tree, materialized beside a real release web
/// build on a dumb static host, and consumed by an UpdateClient over
/// plain HTTP. Transfer behavior is asserted from the host's request log:
/// only changed artifacts move; a rollback repoint moves no payloads.
///
/// Env: AIR_APP (app worktree with the adoption commit), AIR_OUT (work
/// dir), AIR_SERVE_PORT, AIR_FLUTTER (flutter bin), plus the delta
/// toolchain conventions (OKA_SDK_CHECKOUT).
///
/// The app itself needs no browser here: the client under test is the
/// host-side UpdateClient (the same HTTP resolution a web app's nextLoad
/// bootstrap performs); the browser leg of live patching is
/// `live_e2e_web.dart` (ADR-0031 gate 6).
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

import 'oka_ship.dart' show loadDeclaredUnits;
import 'static_host.dart' show startStaticServer;

// ignore_for_file: avoid_print

final appRoot = Platform.environment['AIR_APP']!;
final outDir = Platform.environment['AIR_OUT']!;
final servePort = int.parse(Platform.environment['AIR_SERVE_PORT'] ?? '8744');
final flutterBin = Platform.environment['AIR_FLUTTER'] ?? 'flutter';

const unitFile = 'packages/headless_core/lib/src/fractional_order.dart';
final unitPath = '$appRoot/$unitFile';

const r2Find = '  return String.fromCharCodes([\n'
    '    for (final digit in mid) _alphabet.codeUnitAt(digit),\n'
    '  ]);';
const r2Replace = '  const patchedAlphabet = '
    "'acbdefghijklmnopqrstuvwxyz';\n"
    '  return String.fromCharCodes([\n'
    '    for (final digit in mid) patchedAlphabet.codeUnitAt(digit),\n'
    '  ]);';
const r3Find = r2Replace;
const r3Replace = '  const patchedAlphabet = '
    "'abdcefghijklmnopqrstuvwxyz';\n"
    '  return String.fromCharCodes([\n'
    '    for (final digit in mid) patchedAlphabet.codeUnitAt(digit),\n'
    '  ]);';

/// The store-boundary probe: the top-level const is a declaration —
/// changing it must refuse the ship (gate 3).
const contractFind = "const String _alphabet = 'abcdefghijklmnopqrstuvwxyz';";
const contractReplace =
    "const String _alphabet = 'acbdefghijklmnopqrstuvwxyz';";

Future<void> main() async {
  final original = await File(unitPath).readAsString();
  final r2State = original.replaceFirst(r2Find, r2Replace);
  final channelDir = '$outDir/channel';
  HttpServer? server;
  var failed = false;
  try {
    final toolchain = await resolvePipelineToolchain(
      checkout: Platform.environment['OKA_SDK_CHECKOUT'],
      okaDartKernelRoot: File.fromUri(Platform.script).parent.parent.path,
      workDir: Directory.systemTemp,
      appPackagesConfig: '$appRoot/.dart_tool/package_config.json',
    );
    final compile = pipelineDeltaCompiler(toolchain);
    final units = await loadDeclaredUnits(appRoot);

    // [1] baseline: the store build this channel grows from.
    final base = await shipRevision(
        root: appRoot, units: units, channelDir: channelDir,
        revision: 'web-base');
    _expect(base.mode, 'baseline', 'baseline ship');
    print('air-web: baseline seeded at web-base');

    // A fresh install cannot update while no host serves the channel —
    // and that failure is a receipt, never a silent pass.
    final local =
        const LocalInstall(baseline: 'web-base', appliedRevision: 'web-base');
    var refusedEarly = false;
    try {
      await UpdateClient()
          .apply(_unreachableSource(), local, stageDir: '$outDir/stage-early');
    } on ChannelSourceException catch (_) {
      refusedEarly = true;
    } on SocketException catch (_) {
      refusedEarly = true;
    }
    _expect(refusedEarly, true, 'pre-serve check');
    print('air-web: no host yet -> refusal (never a silent pass)');

    // [2] gate 2: the developer saves a body-only edit; the ship derives
    // the patch — manifest, eligibility, delta — with no patch code.
    await _edit(r2Find, r2Replace);
    final r2 = await shipRevision(
        root: appRoot, units: units, channelDir: channelDir,
        revision: 'web-r2', compile: compile);
    _expect(r2.mode, 'patch', 'r2 ship');
    _expect(r2.deltas.single.unit, 'engine', 'r2 unit');
    print('air-web: shipped web-r2 '
        '(${r2.deltas.single.artifact.bytes}B delta)');

    // [3] gate 3: a contract-touching edit refuses with the store
    // alternative — on the generated path, at plan time.
    await _edit(contractFind, contractReplace);
    final bad = await shipRevision(
        root: appRoot, units: units, channelDir: channelDir,
        revision: 'web-bad', compile: compile);
    _expect(bad.ok, false, 'contract ship must refuse');
    _expectContains(bad.reasons.join(' '), 'store', 'contract refusal');
    await File(unitPath).writeAsString(r2State);
    print('air-web: contract-touching edit refused (store lane named)');

    // [4] materialize on a dumb static host beside the real web build.
    final hostRoot = '$outDir/host';
    final webBuild = await _buildWeb();
    await _copyTree(webBuild, '$hostRoot/app');
    await _copyTree(channelDir, '$hostRoot/channel');
    final logPath = '$outDir/server.log';
    File(logPath).writeAsStringSync('');
    server = await startStaticServer(
        root: hostRoot, port: servePort, logPath: logPath);
    await _expectHttp('http://127.0.0.1:$servePort/app/index.html', 200);
    await _expectHttp(
        'http://127.0.0.1:$servePort/channel/pointer.json', 200);
    print('air-web: host serving app + channel on :$servePort');

    // [5] gate 2 (verify rung): the client transfers ONLY the changed
    // artifact and reports the new revision.
    final source =
        HttpChannelSource(baseUrl: 'http://127.0.0.1:$servePort/channel');
    final receipt =
        await UpdateClient().apply(source, local, stageDir: '$outDir/stage');
    _expect(receipt.ok, true, 'chain apply');
    _expect(receipt.mode, 'chain', 'chain mode');
    _expect(receipt.toRevision, 'web-r2', 'chain target');
    _expect(receipt.steps.single.status, 'applied', 'delta staged');
    _expect(_artifactFetched(), ['artifacts/engine-web-r2.delta.dill'],
        'transfer is changed-artifacts-only');
    print('air-web: verify rung — 1 changed artifact transferred, '
        'digest verified, staged');

    // [6] gate 4: publish web-r3 offline, then repoint the HOST back to
    // web-r2 (the publisher's rollback; the tree keeps every manifest and
    // artifact — no uploads, no deletions).
    await _edit(r3Find, r3Replace);
    final r3 = await shipRevision(
        root: appRoot, units: units, channelDir: channelDir,
        revision: 'web-r3', compile: compile);
    _expect(r3.mode, 'patch', 'r3 ship');
    await _syncWithoutPointer(channelDir, '$hostRoot/channel');
    final hostPointer =
        await _fetchBytes('http://127.0.0.1:$servePort/channel/pointer.json');
    _expect(
        (jsonDecode(utf8.decode(hostPointer)) as Map)['revision'], 'web-r2',
        'host pointer still the rollback target');

    // A client that already took web-r3 cannot follow a repoint back:
    // delta chains do not reverse — the honest refusal.
    final atR3 = const LocalInstall(
        baseline: 'web-base', appliedRevision: 'web-r3');
    final plan = await UpdateClient().check(source, atR3);
    _expect(plan.mode, ChannelPlanMode.refused, 'r3 client after rollback');
    _expectContains(plan.reasons.join(' '), 'not found',
        'rollback refusal names the unknown revision');

    // A client still at web-r2 (its state after the apply above) is
    // simply up to date — with no payload re-fetch (the artifacts never
    // left the host).
    final atR2 = const LocalInstall(
        baseline: 'web-base', appliedRevision: 'web-r2');
    final rolled =
        await UpdateClient().apply(source, atR2, stageDir: '$outDir/stage-r2');
    _expect(rolled.mode, 'upToDate', 'client at r2 after repoint');
    _expect(_artifactFetched(), ['artifacts/engine-web-r2.delta.dill'],
        'rollback moved no payloads');
    print('air-web: pointer repoint — client at r2 up to date, '
        'zero payload fetches');
    print('air-channel web: OK');
  } catch (e) {
    failed = true;
    print('air-channel web: FAILED — $e');
  } finally {
    await server?.close(force: true);
    await File(unitPath).writeAsString(original);
  }
  exit(failed ? 1 : 0);
}

// --- steps -----------------------------------------------------------------

Future<void> _edit(String find, String replace) async {
  final current = await File(unitPath).readAsString();
  final next = current.replaceFirst(find, replace);
  if (next == current) {
    throw StateError('edit marker not found in $unitFile:\n$find');
  }
  await File(unitPath).writeAsString(next);
}

/// The pre-serve probe must fail because nothing serves the channel —
/// point the source at a closed port on loopback.
ChannelSource _unreachableSource() =>
    HttpChannelSource(baseUrl: 'http://127.0.0.1:9/channel');

Future<String> _buildWeb() async {
  print('air-web: flutter build web --release…');
  final r = await Process.run(
      flutterBin, ['build', 'web', '--release'],
      workingDirectory: appRoot);
  if (r.exitCode != 0) {
    throw StateError('flutter build web failed:\n'
        '${r.stdout}\n${r.stderr}');
  }
  return '$appRoot/build/web';
}

Future<void> _copyTree(String from, String to, {String? skipName}) async {
  final src = Directory(from);
  if (!src.existsSync()) throw StateError('missing dir to copy: $from');
  await for (final e in src.list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(from.length);
    if (skipName != null && rel.contains(skipName)) continue;
    final target = File('$to$rel');
    target.createSync(recursive: true);
    await e.copy(target.path);
  }
}

/// The gate analogue of `git push` for a branch repoint that must NOT
/// carry a new pointer: manifests/artifacts sync, the host pointer stays.
Future<void> _syncWithoutPointer(String channelDir, String hostChannel) =>
    _copyTree(channelDir, hostChannel, skipName: 'pointer.json');

Future<List<int>> _fetchBytes(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('GET $url -> ${response.statusCode}');
    }
    return await response.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk));
  } finally {
    client.close();
  }
}

Future<void> _expectHttp(String url, int want) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode != want) {
      throw StateError('GET $url -> ${response.statusCode} (want $want)');
    }
  } finally {
    client.close();
  }
}

/// Artifact paths fetched with a 200 so far, in order.
List<String> _artifactFetched() {
  final log = File('$outDir/server.log').readAsStringSync();
  return const LineSplitter()
      .convert(log)
      .where((l) => l.trim().isNotEmpty)
      .map((l) => (jsonDecode(l) as Map).cast<String, dynamic>())
      .where((e) =>
          e['status'] == 200 &&
          (e['path'] as String).startsWith('/channel/artifacts/'))
      .map((e) => (e['path'] as String).substring('/channel/'.length))
      .toList();
}

void _expect(Object? actual, Object? want, String what) {
  if (actual is List && want is List) {
    if (actual.length != want.length ||
        !List.generate(want.length, (i) => actual[i] == want[i])
            .every((e) => e)) {
      throw StateError('$what: got $actual, want $want');
    }
    return;
  }
  if (actual != want) {
    throw StateError('$what: got `$actual`, want `$want`');
  }
}

void _expectContains(String actual, String needle, String what) {
  if (!actual.contains(needle)) {
    throw StateError('$what: `$actual` does not mention `$needle`');
  }
}
