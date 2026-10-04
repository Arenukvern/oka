/// `oka ship` runner — the invisible patch authoring command
/// (ADR-0037 §1). Derives everything below the unit declaration:
/// revision from git, manifests from the tree, eligibility from the
/// manifests, deltas from the changed units, channel tree from the plan.
///
///   dart tool/oka_ship.dart [--project <dir>] [--channel-dir <dir>] \
///     [--revision <id>] [--snapshot <file>] [--dry-run] [--json]
///
/// The published `oka` CLI delegates here (same posture as `oka live`,
/// ADR-0036): the experimental stack is `publish_to: none`, so the
/// published package takes no non-publishable dependency.
///
/// Exit 0 only when the receipt is ok.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

import 'flutter_delta.dart' show flutterToolchainPaths;

// ignore_for_file: avoid_print

const _usage = 'usage: oka ship [--project <dir>] [--channel-dir <dir>]\n'
    '  --revision <id>      publish under this id (default: git HEAD)\n'
    '  --snapshot <file>    attach a whole-revision snapshot artifact\n'
    '  --snapshot-from-build[=<dir|file>]  derive the snapshot from the\n'
    '                       build pipeline and attach it: a directory is\n'
    '                       archived (web build, app bundle), a file is\n'
    '                       staged as-is; with no value the whole-revision\n'
    '                       kernel is compiled from the entrypoint. Even\n'
    '                       without this flag a snapshot is derived\n'
    '                       automatically when the chain would overrun the\n'
    '                       pointer policy (G-AC6)\n'
    '  --max-chain-bytes <n>    publisher policy override (pointer)\n'
    '  --max-chain-revisions <n> publisher policy override (pointer)\n'
    '  --publish-git <repo> materialize the channel as an orphan branch in\n'
    '                       this local repo (the OSS git-channel story)\n'
    '  --git-branch <name>  branch name (default: oka-channel)\n'
    '  --signing-key <file> hex ed25519 seed; signs pointer + manifests\n'
    '  --generate-signing-key <file>  write a new seed, print the trust\n'
    '                       anchor (public key), exit\n'
    '  --dry-run            derive everything, publish nothing\n'
    '  --json               emit the receipt as JSON\n'
    '\n'
    'Units are declared once in tool/patch_units.dart '
    '(`UnitsSpec patchUnits`) — never per patch.';

/// Parsed `oka ship` arguments.
class ShipArgs {
  const ShipArgs({
    required this.project,
    required this.channelDir,
    this.revision,
    this.snapshotFile,
    this.snapshotFromBuild,
    this.maxChainBytes,
    this.maxChainRevisions,
    this.publishGit,
    this.gitBranch = 'oka-channel',
    this.signingKeyFile,
    this.generateSigningKeyTo,
    this.dryRun = false,
    this.jsonOut = false,
  });

  final String project;
  final String channelDir;
  final String? revision;
  final String? snapshotFile;

  /// `--snapshot-from-build`: empty string = derive (compile the
  /// whole-revision kernel); non-empty = a build output dir (archived) or
  /// file (staged as-is). Null = flag absent.
  final String? snapshotFromBuild;
  final int? maxChainBytes;
  final int? maxChainRevisions;
  final String? publishGit;
  final String gitBranch;
  final String? signingKeyFile;

  /// Utility mode: generate a key into [generateSigningKeyTo], print the
  /// trust anchor, exit 0.
  final String? generateSigningKeyTo;
  final bool dryRun;
  final bool jsonOut;

  /// Null when the invocation is malformed; [error] then says why.
  static ShipArgs? parse(List<String> args, {String? cwd}) {
    String? project = cwd;
    String? channelDir;
    String? revision;
    String? snapshotFile;
    String? snapshotFromBuild;
    int? maxChainBytes;
    int? maxChainRevisions;
    String? publishGit;
    var gitBranch = 'oka-channel';
    String? signingKeyFile;
    String? generateKeyTo;
    var dryRun = false;
    var jsonOut = false;
    String? value(final String name, final String arg, final int i) {
      if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
      if (arg == '--$name' && i + 1 < args.length) return args[i + 1];
      return null;
    }

    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      final projV = value('project', a, i);
      if (projV != null) {
        project = projV;
        if (a == '--project') i++;
        continue;
      }
      final chanV = value('channel-dir', a, i);
      if (chanV != null) {
        channelDir = chanV;
        if (a == '--channel-dir') i++;
        continue;
      }
      final revV = value('revision', a, i);
      if (revV != null) {
        revision = revV;
        if (a == '--revision') i++;
        continue;
      }
      final snapV = value('snapshot', a, i);
      if (snapV != null) {
        snapshotFile = snapV;
        if (a == '--snapshot') i++;
        continue;
      }
      if (a == '--snapshot-from-build' ||
          a.startsWith('--snapshot-from-build=')) {
        // Optional value: a following token that is itself a flag means
        // "derive", not "archive that flag".
        final next = i + 1 < args.length ? args[i + 1] : null;
        snapshotFromBuild = a.contains('=')
            ? a.substring('--snapshot-from-build='.length)
            : (next != null && !next.startsWith('--') ? next : '');
        if (a == '--snapshot-from-build' &&
            next != null &&
            !next.startsWith('--')) {
          i++;
        }
        continue;
      }
      final bytesV = value('max-chain-bytes', a, i);
      if (bytesV != null) {
        maxChainBytes = int.tryParse(bytesV);
        if (maxChainBytes == null) return null;
        if (a == '--max-chain-bytes') i++;
        continue;
      }
      final revsV = value('max-chain-revisions', a, i);
      if (revsV != null) {
        maxChainRevisions = int.tryParse(revsV);
        if (maxChainRevisions == null) return null;
        if (a == '--max-chain-revisions') i++;
        continue;
      }
      final gitV = value('publish-git', a, i);
      if (gitV != null) {
        publishGit = gitV;
        if (a == '--publish-git') i++;
        continue;
      }
      final branchV = value('git-branch', a, i);
      if (branchV != null) {
        gitBranch = branchV;
        if (a == '--git-branch') i++;
        continue;
      }
      final keyV = value('signing-key', a, i);
      if (keyV != null) {
        signingKeyFile = keyV;
        if (a == '--signing-key') i++;
        continue;
      }
      final genV = value('generate-signing-key', a, i);
      if (genV != null) {
        generateKeyTo = genV;
        if (a == '--generate-signing-key') i++;
        continue;
      }
      if (a == '--dry-run') {
        dryRun = true;
      } else if (a == '--json') {
        jsonOut = true;
      } else {
        return null; // unknown token
      }
    }
    if (project == null) return null;
    return ShipArgs(
      project: project,
      channelDir: channelDir ?? '$project/build/oka-channel',
      revision: revision,
      snapshotFile: snapshotFile,
      snapshotFromBuild: snapshotFromBuild,
      maxChainBytes: maxChainBytes,
      maxChainRevisions: maxChainRevisions,
      publishGit: publishGit,
      gitBranch: gitBranch,
      signingKeyFile: signingKeyFile,
      generateSigningKeyTo: generateKeyTo,
      dryRun: dryRun,
      jsonOut: jsonOut,
    );
  }
}

/// The CLI body, DI-able for tests (units/revision/compiler overrides
/// instead of probe/git/toolchain; injected sinks instead of stdout).
Future<void> runShipCli(
  List<String> args, {
  UnitDeltaCompiler? compiler,
  Future<List<PatchUnit>> Function(String project)? unitsProvider,
  String? Function(String project)? revisionProvider,
  void Function(String)? output,
  void Function(String)? errorOutput,
  void Function(int)? setExitCode,
  String? kernelRoot,
  String? workingDir,
}) async {
  final out = output ?? print;
  final err = errorOutput ?? (final m) => stderr.writeln(m);
  final exitWith = setExitCode ?? (final c) => exitCode = c;

  final args0 = args.isNotEmpty && args.first == 'ship' ? args.sublist(1) : args;
  final parsed = ShipArgs.parse(args0, cwd: workingDir ?? Directory.current.path);
  if (parsed == null) {
    err(_usage);
    exitWith(2);
    return;
  }

  if (parsed.generateSigningKeyTo != null) {
    final signer = await ChannelSigner.generate();
    File(parsed.generateSigningKeyTo!)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${await signer.keySeedHex()}\n');
    out('signing key written: ${parsed.generateSigningKeyTo!}');
    out('trust anchor (embed in the app): ${signer.publicKeyHex}');
    out('keyId: ${signer.keyId}');
    return;
  }

  try {
    ChannelSigner? signer;
    if (parsed.signingKeyFile != null) {
      final keyFile = File(parsed.signingKeyFile!);
      if (!keyFile.existsSync()) {
        throw ShipException('signing key file missing: ${parsed.signingKeyFile}');
      }
      signer = await ChannelSigner.fromSeedHex(keyFile.readAsStringSync());
      out(parsed.jsonOut
          ? const JsonEncoder.withIndent('  ')
              .convert({'keyId': signer.keyId, 'publicKey': signer.publicKeyHex})
          : 'signing as ${signer.keyId} (trust anchor: '
              '${signer.publicKeyHex})');
    }
    final units = unitsProvider != null
        ? await unitsProvider(parsed.project)
        : await loadDeclaredUnits(parsed.project);
    final revision = parsed.revision ??
        (revisionProvider != null
            ? revisionProvider(parsed.project)
            : gitRevision(parsed.project)) ??
        (throw ShipException(
            'cannot derive a revision: `${parsed.project}` is not a git '
            'checkout — pass --revision'));

    final compile = compiler ??
        (await resolvePipelineToolchain(
          okaDartKernelRoot:
              kernelRoot ?? File.fromUri(Platform.script).parent.parent.path,
          workDir: Directory.systemTemp,
          appPackagesConfig:
              '${parsed.project}/.dart_tool/package_config.json',
        ).then(pipelineDeltaCompiler));

    // Publisher policy overrides ride the pointer (baseline seeding);
    // existing channels keep their pointer policy.
    final policy =
        parsed.maxChainBytes != null || parsed.maxChainRevisions != null
            ? ChannelPolicy(
                maxChainBytes:
                    parsed.maxChainBytes ?? ChannelPolicy.defaultMaxChainBytes,
                maxChainRevisions: parsed.maxChainRevisions ??
                    ChannelPolicy.defaultMaxChainRevisions)
            : null;

    // Explicit --snapshot-from-build attaches on this ship, always.
    String? explicitSnapshot;
    if (parsed.snapshotFromBuild != null) {
      explicitSnapshot = await buildSnapshotFromPipeline(
        parsed.snapshotFromBuild!.isEmpty ? null : parsed.snapshotFromBuild!,
        project: parsed.project,
        revision: revision,
      );
      out(parsed.jsonOut
          ? const JsonEncoder.withIndent('  ')
              .convert({'snapshot': explicitSnapshot})
          : '  snapshot built: $explicitSnapshot');
    }

    final receipt = await shipRevision(
        root: parsed.project,
        units: units,
        channelDir: parsed.channelDir,
        revision: revision,
        snapshotFile: parsed.snapshotFile ?? explicitSnapshot,
        snapshotBuilder: parsed.snapshotFromBuild == null
            ? () => buildSnapshotFromPipeline(null,
                project: parsed.project, revision: revision)
            : null,
        policy: policy,
        dryRun: parsed.dryRun,
        compile: compile,
        signer: signer);
    out(parsed.jsonOut
        ? const JsonEncoder.withIndent('  ').convert(receipt.toJson())
        : receipt.describe());

    // Git-branch materialization (ADR-0037 G-AC7): only for real ships.
    if (parsed.publishGit != null &&
        receipt.ok &&
        !parsed.dryRun &&
        receipt.mode != 'nothing-to-ship') {
      final git = await publishChannelToGit(
          channelDir: parsed.channelDir,
          repo: parsed.publishGit!,
          branch: parsed.gitBranch,
          message: 'oka ship: $revision');
      if (parsed.jsonOut) {
        out(const JsonEncoder.withIndent('  ').convert(git.toJson()));
      } else if (git.ok) {
        out('  git: branch ${git.branch} at '
            '${git.commit!.substring(0, 12)} (${git.files} files, '
            '${git.bytes}B) in ${git.repo}');
      } else {
        err(git.reasons.join('\n'));
        exitWith(1);
        return;
      }
    }
    exitWith(receipt.ok ? 0 : 1);
  } on ShipException catch (e) {
    err('oka ship: ${e.message}');
    exitWith(1);
  } catch (e) {
    err('oka ship: $e');
    exitWith(1);
  }
}

/// Revision id from git (short 12); null when this is not a checkout.
String? gitRevision(String project) {
  final result = Process.runSync('git', ['rev-parse', '--short=12', 'HEAD'],
      workingDirectory: project);
  if (result.exitCode != 0) return null;
  return (result.stdout as String).trim();
}

/// Discovers the declared units (ADR-0037 §1): `tool/patch_units.dart`
/// exposing `UnitsSpec patchUnits`. Runs a generated probe under the
/// project's own package config so the declaration stays plain project
/// Dart — no config files, no annotations.
Future<List<PatchUnit>> loadDeclaredUnits(String project) async {
  final unitsFile = File('$project/tool/patch_units.dart');
  if (!unitsFile.existsSync()) {
    throw ShipException(
        'no tool/patch_units.dart under $project — declare units once '
        '(ADR-0037 §1):\n\n'
        "import 'package:oka_update/oka_update.dart';\n\n"
        "final patchUnits = UnitsSpec(revision: 'baseline', units: [\n"
        "  PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),\n"
        ']);\n');
  }
  final probe = File(
      '${Directory.systemTemp.createTempSync('oka-ship-probe-').path}'
      '/probe.dart');
  probe.writeAsStringSync('''
import 'dart:convert';
import '${Uri.file(unitsFile.path)}' as units;

void main() {
  print(jsonEncode({
    'units': [
      for (final u in units.patchUnits.units)
        {'name': u.name, 'libraries': u.libraries},
    ],
  }));
}
''');
  final packagesConfig = '$project/.dart_tool/package_config.json';
  if (!File(packagesConfig).existsSync()) {
    throw ShipException(
        'run dart pub get in $project first (missing package_config.json)');
  }
  final result = await Process.run(
      'dart', ['run', '--packages=$packagesConfig', probe.path],
      workingDirectory: project);
  _cleanup(probe.parent);
  if (result.exitCode != 0) {
    throw ShipException(
        'tool/patch_units.dart does not expose `UnitsSpec patchUnits` '
        '(probe failed):\n${result.stderr}');
  }
  final line = (result.stdout as String)
      .split('\n')
      .lastWhere((l) => l.trim().startsWith('{'), orElse: () => '');
  if (line.isEmpty) {
    throw ShipException('units probe printed no JSON — declaration shape?');
  }
  final decoded = (jsonDecode(line) as Map).cast<String, dynamic>();
  return [
    for (final u in (decoded['units'] as List).cast<Map>())
      PatchUnit(
          name: u['name'] as String,
          libraries: (u['libraries'] as List).cast<String>()),
  ];
}

void _cleanup(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Temp cleanup is best-effort.
  }
}

/// Derives a whole-revision snapshot artifact from the build pipeline
/// (ADR-0037 G-AC6). [from] names a build output: a directory is archived
/// (`tar.gz` — a web build, an app bundle), a file is staged as-is; null
/// compiles the whole-revision kernel from the project entrypoint (flutter
/// frontend when the project is a flutter app, `dart compile kernel`
/// otherwise). Returns the local artifact path the ship stages.
Future<String> buildSnapshotFromPipeline(
    String? from, {
    required String project,
    required String revision,
    String? flutterBin,
  }) async {
  final work = Directory.systemTemp.createTempSync('oka-ship-snapshot-');
  if (from != null) {
    final f = File(from);
    final d = Directory(from);
    if (f.existsSync()) return f.absolute.path;
    if (d.existsSync()) {
      final out = '${work.path}/$revision.snapshot.tgz';
      final r = await Process.run('tar',
          ['-czf', out, '-C', d.absolute.path, '.']);
      if (r.exitCode != 0) {
        _cleanup(work);
        throw ShipException('snapshot archive failed: ${r.stderr}');
      }
      return out;
    }
    _cleanup(work);
    throw ShipException(
        'snapshot build output missing: $from — build first (e.g. '
        '`flutter build web`) or point --snapshot-from-build at the '
        'artifact');
  }

  final entry = _entrypoint(project);
  final isFlutter = File('$project/pubspec.yaml').readAsLinesSync().any(
      (l) => l.trim() == 'flutter:' || l.trim().startsWith('flutter:'));
  final out = '${work.path}/$revision.snapshot.dill';
  final ProcessResult r;
  if (isFlutter) {
    final bin = flutterBin ??
        Platform.environment['FLUTTER_BIN'] ??
        _discoverFlutterBin();
    final (dartSdk, frontend, patchedSdk) = flutterToolchainPaths(bin);
    final packages = '$project/.dart_tool/package_config.json';
    if (!File(packages).existsSync()) {
      _cleanup(work);
      throw ShipException(
          'run `flutter pub get` in $project first (missing '
          'package_config.json)');
    }
    r = await Process.run('$dartSdk/bin/dartaotruntime', [
      frontend,
      '--sdk-root=$patchedSdk',
      '--target=flutter',
      '--packages=$packages',
      '--output-dill=$out',
      entry,
    ]);
  } else {
    r = await Process.run('dart', ['compile', 'kernel', '--output', out, entry],
        workingDirectory: project);
  }
  if (r.exitCode != 0 || !File(out).existsSync()) {
    _cleanup(work);
    throw ShipException('whole-revision snapshot compile failed:\n'
        '${r.stdout}\n${r.stderr}');
  }
  return out;
}

/// The app entrypoint a whole-revision kernel compiles from.
String _entrypoint(String project) {
  for (final candidate in ['lib/main.dart', 'bin/main.dart']) {
    if (File('$project/$candidate').existsSync()) return '$project/$candidate';
  }
  final pkg = project.split('/').last;
  if (File('$project/bin/$pkg.dart').existsSync()) {
    return '$project/bin/$pkg.dart';
  }
  throw ShipException(
      'no entrypoint to derive a snapshot from (expected lib/main.dart) — '
      'pass --snapshot-from-build <build-output> or --snapshot <file>');
}

/// Flutter binary discovery: PATH first, then the fvm default checkout
/// this machine's gates conventionally use.
String _discoverFlutterBin() {
  final which = Process.runSync('which', ['flutter']);
  if (which.exitCode == 0) return (which.stdout as String).trim();
  final fvm =
      '${Platform.environment['HOME']}/fvm/default/bin/flutter';
  if (File(fvm).existsSync()) return fvm;
  return 'flutter';
}

Future<void> main(List<String> args) => runShipCli(args);
