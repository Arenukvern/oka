import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'owned_dev_session.dart';

/// L0 Linux desktop dev gates driven from Dart (ADR-0036 / UA review).
final class LinuxDevGate {
  LinuxDevGate({
    required this.workspace,
    this.appProject = 'example',
    this.useXvfb = false,
    this.outDir,
    this.sessionStart = OwnedDevSession.start,
    this.sessionSpawn = OwnedDevSession.defaultDevSessionSpawn,
  });

  final String workspace;
  final String appProject;
  final bool useXvfb;
  final String? outDir;
  final Future<OwnedDevSession> Function({
    required String workspace,
    required List<String> dartInvocation,
    bool useXvfb,
    String? workingDirectory,
    Map<String, String>? environment,
    Duration identityBudget,
    DevSessionSpawner spawn,
  }) sessionStart;
  final DevSessionSpawner sessionSpawn;

  String get _appRoot => p.join(workspace, appProject);
  String get _okaDart => p.join(workspace, 'packages/oka/bin/oka.dart');
  String get _packageConfig =>
      p.join(workspace, '.dart_tool/package_config.json');

  /// Public `oka run dev` CLI (kernel stack auto-discovery from script path).
  List<String> _devInvocation({
    required List<String> extra,
  }) =>
      [
        '--packages=$_packageConfig',
        _okaDart,
        'run',
        'dev',
        '--project',
        _appRoot,
        '--platform',
        'linux',
        '--no-watch',
        ...extra,
      ];

  String? get _sessionCwd {
    final fromEnv = Platform.environment['OKA_LINUX_DEV_GATE_CWD']?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    return null;
  }

  Future<int> runReloadLeg() async {
    final out = outDir ?? p.join(workspace, 'packages/oka_dart_kernel/.gate_run_dev_linux');
    await Directory(out).create(recursive: true);
    final unitFile = p.join(_appRoot, 'lib/units/feature.dart');
    final original = await File(unitFile).readAsString();
    Future<void> restore() async {
      await File(unitFile).writeAsString(original);
    }

    final probes = p.join(out, 'probes-linux.json');
    await File(probes).writeAsString(
      '[{"library": "units/feature.dart", "expression": "featureLabel()", '
      '"expect": "feature-v2-live"}]\n',
    );

    OwnedDevSession? session;
    var exitCode = 1;
    try {
      session = await sessionStart(
        workspace: workspace,
        dartInvocation: _devInvocation(extra: ['--probes', probes]),
        useXvfb: useXvfb,
        workingDirectory: _sessionCwd,
        spawn: sessionSpawn,
      );

      if (!await session.waitForPattern('dev: ready')) {
        stderr.writeln('gate: timeout waiting for dev session (linux)');
        stderr.writeln('gate: --- log tail (last 40 lines) ---');
        final lines = session.transcript.split('\n');
        stderr.writeln(lines.skip(lines.length > 40 ? lines.length - 40 : 0).join('\n'));
        return 1;
      }
      await session.snapshotOwnedTree();

      final vmUri = _extractVmUri(session.transcript);
      if (vmUri == null) {
        stderr.writeln('FAIL: no VM uri before reload');
        return 1;
      }

      if (!await _vmProbesOk(
        workspace: workspace,
        outDir: out,
        vmUri: vmUri,
        tag: 'reload-pre',
        probes: const [
          _VmProbe('devGateSessionBump()', '1'),
          _VmProbe('devGateSessionTick()', '1'),
        ],
      )) {
        stderr.writeln('FAIL: session tick bump (pre-reload)');
        return 1;
      }

      final edited = original.replaceFirst('feature-v1', 'feature-v2-live');
      if (!edited.contains('feature-v2-live')) {
        stderr.writeln('FAIL: edit (linux)');
        return 1;
      }
      await File(unitFile).writeAsString(edited);

      session.sendLine('r $unitFile');
      if (!await session.waitForPattern('reload 1: OK', timeout: const Duration(minutes: 2))) {
        stderr.writeln('gate: timeout hot reload (linux)');
        return 1;
      }
      if (!session.transcript.contains('feature-v1 -> feature-v2-live') &&
          !session.transcript.contains('feature-v2-live')) {
        stderr.writeln('FAIL: probe did not flip (linux)');
        return 1;
      }

      final vmAfterReload = _extractVmUri(session.transcript) ?? vmUri;
      if (!await _vmProbesOk(
        workspace: workspace,
        outDir: out,
        vmUri: vmAfterReload,
        tag: 'reload-post',
        probes: const [
          _VmProbe('devGateSessionTick()', '1'),
        ],
      )) {
        stderr.writeln(
          'FAIL: hot reload must preserve in-memory session tick '
          '(got != 1)',
        );
        return 1;
      }

      if (!await _vmProbesOk(
        workspace: workspace,
        outDir: out,
        vmUri: vmAfterReload,
        tag: 'reload-bump',
        probes: const [
          _VmProbe('devGateSessionBump()', '2'),
        ],
      )) {
        stderr.writeln('FAIL: session tick bump before restart');
        return 1;
      }

      session.sendLine('R');
      if (!await session.waitForPattern(
        'restart: OK (platform lane',
        timeout: const Duration(minutes: 3),
      )) {
        stderr.writeln('FAIL: platform hot restart receipt missing');
        stderr.writeln('gate: --- session tail ---');
        _logTail(session.transcript);
        exitCode = 1;
      } else if (!session.transcript.contains('Restarted application')) {
        stderr.writeln('FAIL: platform state-reset line missing from session');
        _logTail(session.transcript);
        exitCode = 1;
      } else {
        final vmAfterRestart = _extractVmUri(session.transcript) ?? vmAfterReload;
        if (!await _vmProbesOk(
          workspace: workspace,
          outDir: out,
          vmUri: vmAfterRestart,
          tag: 'restart-reset',
          probes: const [
            _VmProbe('devGateSessionTick()', '0'),
          ],
        )) {
          stderr.writeln(
            'FAIL: hot restart must reset in-memory session tick to 0',
          );
          exitCode = 1;
        } else {
          exitCode = 0;
        }
      }
    } finally {
      await restore();
      if (session != null) {
        final td = await session.teardown();
        if (!td.clean) {
          stderr.writeln(
            'gate: teardown incomplete (survivors: ${td.survivors}; '
            '${td.notes.join('; ')})',
          );
          exitCode = 1;
        }
      }
    }
    return exitCode;
  }

  Future<int> runAssetsLeg() async {
    final out =
        outDir ?? p.join(workspace, 'packages/oka_dart_kernel/.gate_dev_assets_linux');
    await Directory(out).create(recursive: true);
    final assetFile = p.join(_appRoot, 'assets/hello.txt');
    final leafFile = p.join(_appRoot, 'lib/units/feature.dart');
    final originalAsset = await File(assetFile).readAsString();
    final originalLeaf = await File(leafFile).readAsString();
    Future<void> restore() async {
      await File(assetFile).writeAsString(originalAsset);
      await File(leafFile).writeAsString(originalLeaf);
    }

    final newContent = 'asset-sync-gate-linux-${DateTime.now().millisecondsSinceEpoch}';
    final bytes = utf8.encode(newContent);
    var sum = 0;
    for (final b in bytes) {
      sum += b;
    }
    final fprint = bytes.length * 1000003 + sum;

    OwnedDevSession? session;
    var exitCode = 1;
    try {
      stderr.writeln('== [1/5] boot example under oka run dev --platform linux');
      session = await sessionStart(
        workspace: workspace,
        dartInvocation: _devInvocation(extra: ['--json']),
        useXvfb: useXvfb,
        workingDirectory: _sessionCwd,
        spawn: sessionSpawn,
      );

      if (!await session.waitForPattern('dev: ready')) {
        stderr.writeln('gate: timeout waiting for dev session (linux)');
        return 1;
      }
      await session.snapshotOwnedTree();

      stderr.writeln('== [2/5] r <leaf dart>: delta lane');
      await File(leafFile).writeAsString(
        originalLeaf.replaceFirst('feature-v1', 'feature-v2-live'),
      );
      session.sendLine('r lib/units/feature.dart');
      if (!await session.waitForPattern('reload 1: OK', timeout: const Duration(minutes: 2))) {
        return 1;
      }
      if (!session.transcript.contains('"reassemble": "ok"')) {
        stderr.writeln('FAIL: reassemble missing');
        return 1;
      }

      stderr.writeln('== [3/5] r <asset>: sync lane');
      await File(assetFile).writeAsString(newContent);
      session.sendLine('r assets/hello.txt');
      if (!await session.waitForPattern('assets 2:', timeout: const Duration(minutes: 1))) {
        return 1;
      }
      if (!session.transcript.contains('assets 2: OK')) {
        stderr.writeln('FAIL: asset sync not OK');
        return 1;
      }
      if (!session.transcript.contains('"evict": "ok"')) {
        stderr.writeln('FAIL: ext.flutter.evict');
        return 1;
      }

      stderr.writeln('== [4/5] R: engine picks synced bytes');
      session.sendLine('R');
      if (!await session.waitForPattern(
        'restart: OK (platform lane',
        timeout: const Duration(minutes: 3),
      )) {
        stderr.writeln('FAIL: restart receipt missing');
        _logTail(session.transcript);
        exitCode = 1;
      } else if (!session.transcript.contains('Restarted application')) {
        stderr.writeln('FAIL: platform state-reset line missing');
        _logTail(session.transcript);
        exitCode = 1;
      } else {
        exitCode = 0;
      }

      if (exitCode == 0) {
      stderr.writeln('== [5/5] verify fingerprint via VM');
      final vmUri = _extractVmUri(session.transcript);
      if (vmUri == null) {
        stderr.writeln('FAIL: no VM uri');
        return 1;
      }
      if (!await _vmProbesOk(
        workspace: workspace,
        outDir: out,
        vmUri: vmUri,
        tag: 'assets-fingerprint',
        probes: [_VmProbe('helloAssetFingerprint()', '$fprint')],
      )) {
        stderr.writeln('FAIL: post-restart asset fingerprint not verified');
        exitCode = 1;
      } else if (!await _vmProbesOk(
        workspace: workspace,
        outDir: out,
        vmUri: vmUri,
        tag: 'assets-restart-tick',
        probes: const [_VmProbe('devGateSessionTick()', '0')],
      )) {
        stderr.writeln('FAIL: asset leg restart did not reset session tick');
        exitCode = 1;
      } else {
        exitCode = 0;
      }
      }
    } finally {
      await restore();
      if (session != null) {
        final td = await session.teardown();
        if (!td.clean) {
          stderr.writeln(
            'gate: teardown incomplete (survivors: ${td.survivors})',
          );
          exitCode = 1;
        }
      }
    }
    return exitCode;
  }

  static void _logTail(String transcript) {
    final lines = transcript.split('\n');
    final tail = lines.skip(lines.length > 40 ? lines.length - 40 : 0).join('\n');
    stderr.writeln(tail);
  }

  static String? _extractVmUri(String transcript) {
    final re = RegExp(
      r'VM service at (http://127\.0\.0\.1:\d+/[A-Za-z0-9_%-]+=)',
    );
    final matches = re.allMatches(transcript).toList();
    if (matches.isEmpty) return null;
    return matches.last.group(1);
  }

  Future<bool> _vmProbesOk({
    required String workspace,
    required String outDir,
    required String vmUri,
    required String tag,
    required List<_VmProbe> probes,
  }) async {
    final verifySpec = {
      'revision': 'gate-$tag',
      'unit': 'gate',
      'patches': <Object>[],
      'targets': [
        {
          'kind': 'vm',
          'id': 'app',
          'ws': '${vmUri.replaceFirst('http', 'ws')}/ws',
          'http': vmUri,
          'devfs': 'oka_gate_verify_linux_$tag',
          'applyVia': 'reloadSources',
        },
      ],
      'probes': [
        for (final p in probes)
          {
            'library': 'main.dart',
            'expression': p.expression,
            'expect': p.expect,
          },
      ],
    };
    final specPath = p.join(outDir, 'verify-$tag.json');
    await File(specPath).writeAsString(jsonEncode(verifySpec));
    final live = p.join(workspace, 'packages/oka_dart_kernel/tool/oka_live.dart');
    final result = await runBoundedProcess(
      Platform.resolvedExecutable,
      ['--packages=$_packageConfig', live, 'verify', '--spec', specPath],
      timeout: const Duration(minutes: 3),
      workingDirectory: workspace,
    );
    final logPath = p.join(outDir, 'verify-$tag.log');
    await File(logPath).writeAsString(
      'exit=${result.exitCode}\n${result.stdout}\n${result.stderr}',
    );
    return result.exitCode == 0 && result.stdout.contains('live patch OK');
  }
}

final class _VmProbe {
  const _VmProbe(this.expression, this.expect);
  final String expression;
  final String expect;
}
