/// The air-channel arc, app-agnostic (ADR-0037 G-AC7): declare -> ship ->
/// git branch -> client fetch/verify/stage -> boot the target -> apply
/// the FETCHED delta over the VM service -> probes. One pid, boot state
/// held. The APP owns every app-specific fact via env (the gate is the
/// thin shell that provides them, ADR-0036 Tier 0):
///
///   AIR_WT                 the app worktree (clean; tool/patch_units.dart
///                          declared — the app's own adoption file)
///   AIR_ORIGIN             scratch git repo standing in for `origin`
///   AIR_OUT                scratch output (channel, clone, stage, logs)
///   AIR_EDIT_FILE          the developer's edit: app-root-relative path
///   AIR_EDIT_FIND          exact substring to replace (the old body)
///   AIR_EDIT_REPLACE       its replacement (the new body)
///   AIR_PORT               the target's VM service port
///   AIR_BOOT_ARGS          how to boot the target ('file args...')
///   AIR_BOOT_MARKER        the log line proving boot
///   AIR_PROBE_LIBRARY      the library the probe expressions evaluate in
///   AIR_PROBE_CHANGE_EXPR  expression that must flip after the patch
///   AIR_PROBE_CHANGE_WANT  substring the flipped value must contain
///   AIR_PROBE_CHANGE_BEFORE substring the pre-patch value must contain
///   AIR_PROBE_HOLD_EXPR    expression that must NOT change (boot state)
///
/// Nothing here knows which app it is.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

import 'oka_ship.dart' show gitRevision, loadDeclaredUnits;

// ignore_for_file: avoid_print

String env(String name) {
  final v = Platform.environment[name];
  if (v == null || v.isEmpty) {
    print('REFUSED: missing env $name');
    exit(2);
  }
  return v;
}

Future<void> main() async {
  final wt = env('AIR_WT');
  final origin = env('AIR_ORIGIN');
  final out = env('AIR_OUT');
  final editFile = env('AIR_EDIT_FILE');
  final editFind = env('AIR_EDIT_FIND');
  final editReplace = env('AIR_EDIT_REPLACE');
  final port = env('AIR_PORT');
  final bootArgs = env('AIR_BOOT_ARGS').split(' ');
  final bootMarker = env('AIR_BOOT_MARKER');
  final probeLibrary = env('AIR_PROBE_LIBRARY');
  final changeExpr = env('AIR_PROBE_CHANGE_EXPR');
  final changeWant = env('AIR_PROBE_CHANGE_WANT');
  final changeBefore = env('AIR_PROBE_CHANGE_BEFORE');
  final holdExpr = env('AIR_PROBE_HOLD_EXPR');
  // G-AC5: when the gate provides a signing key, the channel is signed
  // and the client carries the matching trust anchor (embedded-at-build
  // time in a real app).
  final signKeyPath = Platform.environment['AIR_SIGN_KEY'];

  // [1] The app declared its units (its own tool/patch_units.dart, read
  // through the real probe — no injected fixtures).
  final units = await loadDeclaredUnits(wt);
  print('== [1] units declared: '
      '${units.map((u) => '${u.name}(${u.libraries.length})').join(', ')}');

  final compile = pipelineDeltaCompiler(await resolvePipelineToolchain(
    okaDartKernelRoot: File.fromUri(Platform.script).parent.parent.path,
    workDir: Directory.systemTemp,
    appPackagesConfig: '$wt/.dart_tool/package_config.json',
  ));

  // [2] Baseline ship: digests == exactly what the engine will load.
  final channelDir = '$out/channel';
  final baselineRev = gitRevision(wt)!;
  ChannelSigner? signer;
  String? anchor;
  if (signKeyPath != null) {
    signer = await ChannelSigner.fromSeedHex(
        File(signKeyPath).readAsStringSync());
    anchor = signer.publicKeyHex;
    print('== [2] signing as ${signer.keyId}; client anchor pinned');
  }
  final baseline = await shipRevision(
      root: wt, units: units, channelDir: channelDir,
      revision: baselineRev, signer: signer);
  print('== [2] baseline: ${baseline.describe()}');
  if (baseline.mode != 'baseline') exit(1);

  final client = const UpdateClient();
  final sanity = await client.check(FileChannelSource(channelDir),
      LocalInstall(baseline: baselineRev, trustedPublicKeyHex: anchor));
  print('== [3] client sanity on the fresh channel: ${sanity.mode}');
  if (sanity.mode != ChannelPlanMode.upToDate) exit(1);

  // Boot the target from the same worktree (URI coherence). The patch
  // has not happened yet — the target runs the baseline code.
  final logFile = File('$out/driver.log');
  void tap(Stream<List<int>> stream) {
    stream.transform(utf8.decoder).listen((chunk) {
      // Sync append: the boot wait reads this file between ticks.
      logFile.writeAsStringSync(chunk, mode: FileMode.append);
    });
  }

  final driver = await Process.start('dart',
      ['--enable-vm-service=$port/127.0.0.1', '--disable-service-auth-codes',
       ...bootArgs],
      workingDirectory: wt);
  tap(driver.stdout);
  tap(driver.stderr);
  var booted = false;
  for (var i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (logFile.existsSync() &&
        logFile.readAsStringSync().contains(bootMarker)) {
      booted = true;
      break;
    }
  }
  print('== [4] target booted: $booted (pid ${driver.pid})');
  if (!booted) {
    driver.kill();
    exit(1);
  }

  final target =
      targetFromSpec(TargetSpec.vmPort(int.parse(port), id: 'air-vm'));
  await target.connect();
  ProbeSpec probe(String expression) =>
      ProbeSpec(expression: expression, library: probeLibrary);

  final bootState = await target.evaluate(probe(holdExpr));
  final before = await target.evaluate(probe(changeExpr));
  print('== [5] running (pre-patch): change=$before hold=$bootState');
  if (!before.contains(changeBefore)) {
    driver.kill();
    exit(1);
  }

  // [6] The developer saves — a plain file edit while the target runs.
  final edited = File('$wt/$editFile');
  final source = edited.readAsStringSync();
  if (!source.contains(editFind)) {
    print('REFUSED: edit anchor missing in $editFile');
    driver.kill();
    exit(1);
  }
  edited.writeAsStringSync(source.replaceFirst(editFind, editReplace));

  // [7] The invisible ship: derived, compiled by the real pipeline,
  // published to the git branch.
  final patch = await shipRevision(
      root: wt, units: units, channelDir: channelDir,
      revision: 'air-r2', compile: compile, signer: signer);
  print('== [7] ship rev2: ${patch.describe()}');
  if (patch.mode != 'patch') {
    driver.kill();
    exit(1);
  }

  final published = await publishChannelToGit(
      channelDir: channelDir,
      repo: origin,
      branch: 'oka-channel',
      message: 'oka ship: air-r2');
  print('== [8] git branch: ${published.branch} at '
      '${published.commit!.substring(0, 12)} '
      '(${published.files} files, ${published.bytes}B)');
  if (!published.ok) {
    driver.kill();
    exit(1);
  }

  // [9] The client: read a branch checkout, resolve the chain, verify
  // digests, stage the fetched delta.
  final clone = await checkoutChannelBranch(
      repo: origin, branch: 'oka-channel', into: '$out/clone');
  final fetched = await client.apply(
      FileChannelSource(clone),
      LocalInstall(baseline: baselineRev, trustedPublicKeyHex: anchor),
      stageDir: '$out/stage');
  print('== [9] client apply: ok=${fetched.ok} mode=${fetched.mode} '
      'staged=${fetched.stagedFiles.map((f) => f.split('/').last)}');
  if (!fetched.ok) {
    driver.kill();
    exit(1);
  }
  final stagedDelta = fetched.stagedFiles.single;

  final outcome = await target.apply(
      unit: units.single.name,
      deltaPath: stagedDelta,
      deltaBytes: File(stagedDelta).lengthSync());
  print('== [10] apply the FETCHED delta: ok=${outcome.ok} '
      'mode=${outcome.mode} wire=${outcome.wire}');
  if (!outcome.ok) {
    driver.kill();
    exit(1);
  }

  final after = await target.evaluate(probe(changeExpr));
  final afterState = await target.evaluate(probe(holdExpr));
  print('== [11] after patch: change=$after hold=$afterState '
      '(held=${afterState == bootState})');
  driver.kill();

  final ok = after.contains(changeWant) && afterState == bootState;
  print(ok
      ? 'live patch OK — channel -> git branch -> client -> engine, one pid'
      : 'FAILED');
  exit(ok ? 0 : 1);
}
