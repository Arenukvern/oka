/// Store-backed provisioning of Android device tooling (ADR-0013, T2).
///
/// Resolution is the [AndroidToolchain] policy (T1); provisioning is this
/// class: a platform-scoped tool provider that moves bytes through the
/// shared [ArtifactStore] (T0 contract) when the policy comes up empty.
///
/// The flow for every tool is the same, per ADR-0013:
///
/// 1. resolve through the ordered policy (an existing SDK install wins —
///    provisioning is the last resort, never the default);
/// 2. check the store (content-addressed key — team/`OKA_CACHE`-shareable);
/// 3. on a miss: perform the download **only when a non-interactive path
///    exists** (direct Google repository download for platform-tools; a
///    pre-accepted-license `sdkmanager` for system images). stdin is never
///    read, no prompt is ever answered (ADR-0007);
/// 4. when the only path runs through a prompt-dependent tool, fail with a
///    [ToolchainException] whose `fix` names the exact command to run;
/// 5. register the entry in the store so the next run hits.
///
/// Provisioning of the emulator binary itself is deliberately out of scope
/// here (policy resolution only) — emulator installs are sdkmanager-bound
/// and large; H2 wires boot when the e2e lands.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../build/toolchain.dart';

/// Injectable process runner signature (tests fake `curl`, `sdkmanager`,
/// `chmod` — no network, no real SDK). Named distinctly from oka_core's
/// `ProcessRunner` interface (same idea, raw [ProcessResult] for zip
/// producing commands).
typedef DeviceToolRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
});

/// Platform-scoped tool provider for Android device tooling (ADR-0013, T2).
///
/// - `adb` / platform-tools: policy → store → **direct** download from the
///   Google repository (plain HTTPS, zero interactivity) → store entry.
/// - system images: store (foreign-layout index inside the installed
///   package dir) → non-interactive `sdkmanager` (only when licenses are
///   already accepted) → otherwise fail naming the exact command.
class AndroidDeviceProvisioner {
  AndroidDeviceProvisioner({
    final ArtifactStore? store,
    final DeviceToolRunner? runProcess,
    final String? osOverride,
    this.verbose = false,
  })  : _store = store ?? LocalArtifactStore(),
        _runProcess = runProcess ?? Process.run,
        _os = osOverride ??
            (Platform.isMacOS
                ? 'darwin'
                : Platform.isWindows
                    ? 'windows'
                    : 'linux');

  final ArtifactStore _store;
  final DeviceToolRunner _runProcess;
  final bool verbose;

  /// Host OS tag used in store keys and download URLs.
  final String _os;

  /// Resolves `adb`, provisioning platform-tools through the store when the
  /// policy finds nothing:
  ///
  /// 1. policy (`<sdk>/platform-tools/adb`, ordered, printable);
  /// 2. store hit — the previously downloaded adb binary;
  /// 3. miss — direct `platform-tools-latest-<os>.zip` download from
  ///    dl.google.com (non-interactive by construction; `curl` with stdin
  ///    never attached, extraction in-process), registered in the store.
  ///
  /// Throws [ToolchainException] naming the exact sdkmanager command when
  /// even the direct download fails.
  Future<String> ensureAdb({final ResolvedToolchain? toolchain}) async {
    // 1. Policy first — an existing SDK install always wins.
    final resolved =
        await (toolchain ?? ResolvedToolchain()).resolve(const ToolQuery('adb'));
    if (resolved.ok) return resolved.tool!.path;

    // 2–3. Store-backed provisioning.
    final url =
        'https://dl.google.com/android/repository/platform-tools-latest-$_os.zip';
    final key = ContentKey.compute(
      category: 'platform-tools',
      name: 'adb',
      version: 'latest',
      inputs: ['url:$url'],
      platform: _os,
    );
    final tmp = await Directory.systemTemp.createTemp('oka_platform_tools_');
    try {
      var downloaded = false;
      final stored = await _store.fetch(key, () {
        downloaded = true;
        return _downloadAdb(url, tmp.path);
      });
      if (downloaded && !Platform.isWindows) {
        // Only a fresh extraction needs the executable bit — a store hit
        // already has it (and spawns no process, per the store contract).
        await _runProcess('chmod', ['+x', stored.path]);
      }
      return stored.path;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // best-effort temp cleanup
      }
    }
  }

  /// Downloads and extracts adb for a store miss. Only the `adb` binary is
  /// materialized as the store artifact — it is self-contained in current
  /// platform-tools builds; the rest of the zip is discarded.
  Future<File> _downloadAdb(final String url, final String tmpDir) async {
    final zipPath = p.join(tmpDir, 'platform-tools.zip');
    final download = await _runProcess('curl', [
      '-L', // follow redirects
      '-f', // fail on HTTP errors
      '-o',
      zipPath,
      url,
    ]);
    if (download.exitCode != 0) {
      throw ToolchainException(
        tool: 'adb',
        tried: [
          const ToolSource(ToolSourceKind.managed, 'store miss'),
          ToolSource(ToolSourceKind.managed, 'direct download → $url'),
        ],
        problem: 'platform-tools download failed '
            '(exit ${download.exitCode})',
        fix: 'Run `sdkmanager "platform-tools"` against an existing SDK, or '
            'set OKA_ANDROID_SDK / ANDROID_HOME to an SDK that has '
            'platform-tools. Re-run afterwards — the store will keep it.',
      );
    }
    final zipFile = File(zipPath);
    if (!await zipFile.exists() || await zipFile.length() < 1000) {
      throw ToolchainException(
        tool: 'adb',
        tried: [
          const ToolSource(ToolSourceKind.managed, 'store miss'),
          ToolSource(ToolSourceKind.managed, 'direct download → $url'),
        ],
        problem: 'platform-tools download is missing or truncated',
        fix: 'Run `sdkmanager "platform-tools"` against an existing SDK, or '
            'set OKA_ANDROID_SDK / ANDROID_HOME to an SDK that has '
            'platform-tools.',
      );
    }

    final archive =
        ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final binaryName = Platform.isWindows ? 'adb.exe' : 'adb';
    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (p.basename(entry.name) != binaryName) continue;
      final out = File(p.join(tmpDir, binaryName));
      await out.writeAsBytes(entry.content as List<int>);
      return out;
    }
    throw ToolchainException(
      tool: 'adb',
      tried: [
        const ToolSource(ToolSourceKind.managed, 'store miss'),
        ToolSource(ToolSourceKind.managed, 'direct download → $url'),
      ],
      problem: 'platform-tools zip does not contain $binaryName',
      fix: 'Run `sdkmanager "platform-tools"` against an existing SDK.',
    );
  }

  /// Resolves a system-image package dir (package ids use the sdkmanager
  /// spelling, e.g. `system-images;android-34;google_apis;x86_64`):
  ///
  /// 1. store lookup — the pointer entry registered after a prior install
  ///    (the image itself stays in the SDK where sdkmanager put it — multi-
  ///    GB content is not duplicated; the store records where it lives so
  ///    `oka cache list/gc` can see and address the install);
  /// 2. non-interactive `sdkmanager` install — attempted **only** when a
  ///    sdkmanager exists under the SDK and licenses are already accepted
  ///    (`<sdk>/licenses/` present). stdin is never attached, so a prompt-
  ///    dependent run fails instead of hanging;
  /// 3. otherwise a [ToolchainException] whose fix names the exact command.
  Future<String> ensureSystemImage({
    required final String package,
    final String? sdkRoot,
    final String? sdkManagerPath,
  }) async {
    final key = ContentKey.compute(
      category: 'system-images',
      name: package.replaceAll(';', '_'),
      version: 'latest',
      inputs: ['android-sdk-package:$package'],
    );

    // 1. Store hit: the pointer names the SDK-side package dir; a pointer
    // whose image was hand-deleted is re-provisioned, never trusted.
    final entry = await _store.find(key);
    if (entry != null && await File(entry.path).exists()) {
      try {
        final pointer =
            jsonDecode(await File(entry.path).readAsString())
                as Map<String, dynamic>;
        final packageDir = pointer['package_dir'] as String?;
        if (packageDir != null && await Directory(packageDir).exists()) {
          return packageDir;
        }
      } on FormatException {
        // corrupt pointer — fall through to re-provision
      }
    }

    // 2. Non-interactive sdkmanager path (licenses pre-accepted only).
    final root = sdkRoot ?? await _discoverSdkRoot();
    final manager = sdkManagerPath ??
        await _findSdkManager(root);
    final licensesAccepted = root != null &&
        await Directory(p.join(root, 'licenses')).exists();
    if (manager != null && licensesAccepted) {
      final packageDir = _systemImageDir(root, package);
      final install = await _runProcess(
        manager,
        ['--sdk_root=$root', package],
        environment: {
          ...Platform.environment,
          // sdkmanager must never see a TTY to prompt into.
          'TERM': 'dumb',
        },
      );
      final installed = install.exitCode == 0 &&
          await Directory(packageDir).exists();
      if (installed) {
        await _registerSystemImagePointer(packageDir, package, key, root);
        return packageDir;
      }
      if (verbose) {
        stdout.writeln(
          '⚠️ sdkmanager exited ${install.exitCode} for `$package` '
          '(prompt-dependent run fails closed — never interactive).',
        );
      }
    }

    // 3. Fail naming the exact command (ADR-0007: errors name the fix).
    throw ToolchainException(
      tool: 'system-images',
      tried: [
        const ToolSource(
          ToolSourceKind.managed,
          'artifact store (system-images/<package>)',
        ),
        if (manager == null)
          const ToolSource(
            ToolSourceKind.system,
            'sdkmanager (cmdline-tools) — not found',
          )
        else if (!licensesAccepted)
          const ToolSource(
            ToolSourceKind.system,
            'sdkmanager — SDK licenses not yet accepted',
          )
        else
          const ToolSource(ToolSourceKind.system, 'sdkmanager (exit non-zero)'),
      ],
      problem: 'System image `$package` is not installed and no '
          'non-interactive install path exists.',
      fix: 'Run exactly: sdkmanager --sdk_root=<sdk> "$package" '
          '(accept its license prompt once — that prompt is why oka will '
          'not run it for you), then re-run.',
    );
  }

  /// SDK root for system-image lookups: an env hint or the common oka/system
  /// locations (read-only probe; no download here).
  Future<String?> _discoverSdkRoot() async {
    for (final envName in const [
      'OKA_ANDROID_SDK',
      'ANDROID_HOME',
      'ANDROID_SDK_ROOT',
    ]) {
      final v = Platform.environment[envName];
      if (v != null && v.isNotEmpty && await Directory(v).exists()) {
        return v;
      }
    }
    final home = Platform.environment['HOME'] ?? '';
    for (final candidate in [
      if (home.isNotEmpty) p.join(home, '.oka', 'android-sdk'),
      if (home.isNotEmpty) p.join(home, 'Library', 'Android', 'sdk'),
      if (home.isNotEmpty) p.join(home, 'Android', 'Sdk'),
    ]) {
      if (await Directory(candidate).exists()) return candidate;
    }
    return null;
  }

  Future<String?> _findSdkManager(final String? root) async {
    if (root == null) return null;
    for (final c in [
      p.join(root, 'cmdline-tools', 'latest', 'bin', 'sdkmanager'),
      p.join(root, 'cmdline-tools', 'bin', 'sdkmanager'),
      p.join(root, 'tools', 'bin', 'sdkmanager'),
    ]) {
      if (await File(c).exists()) return c;
    }
    return null;
  }

  /// The SDK-side package dir for an sdkmanager-style package id
  /// (`system-images;android-34;google_apis;x86_64` →
  /// `<sdk>/system-images/android-34/google_apis/x86_64`).
  String _systemImageDir(final String root, final String package) =>
      p.joinAll([root, ...package.split(';')]);

  /// Registers the installed package dir into the store as a pointer entry:
  /// the store artifact is a small JSON file naming the SDK-side package
  /// dir (`package_dir`), content-addressed by the package id. The image
  /// bytes stay in the SDK (sdkmanager owns that layout); the pointer makes
  /// the install visible to `oka cache list/gc` — deleting the entry removes
  /// the record, never SDK-owned content.
  Future<void> _registerSystemImagePointer(
    final String packageDir,
    final String package,
    final ContentKey key,
    final String root,
  ) async {
    try {
      final tmp = await Directory.systemTemp
          .createTemp('oka_sysimage_ptr_');
      try {
        await _store.fetch(key, () async {
          final f = File(p.join(tmp.path, 'install.json'));
          await f.writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'package': package,
              'sdk_root': root,
              'package_dir': packageDir,
              'registered_by': 'device-provisioner',
              'created': DateTime.now().toUtc().toIso8601String(),
            }),
            flush: true,
          );
          return f;
        });
      } finally {
        try {
          await tmp.delete(recursive: true);
        } on FileSystemException {
          // best-effort temp cleanup
        }
      }
    } on FileSystemException {
      // Index registration is best-effort — never fail a resolve over it.
    }
  }
}
