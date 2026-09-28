/// Chrome-for-testing provisioning through the shared artifact store
/// (ADR-0017 S1, ADR-0028 §5).
///
/// The binary is downloaded once per machine into the artifact store
/// (category `chrome-for-testing` — visible to `oka cache list/gc`,
/// shareable via `OKA_CACHE`) and extracted under `~/.oka/tools`. First
/// provisioning is loud and honors `OKA_NO_AUTO_INSTALL=1` (ADR-0007).
/// Resolution order: explicit path → `OKA_CHROME_BIN` → provisioned →
/// system Chrome → provision.
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Last-known-good versions manifest (Google-maintained, no account).
// Single literal: a URL must not be split across adjacent strings.
// ignore: lines_longer_than_80_chars
const kChromeForTestingVersionsUrl = 'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json';

/// Download URL for one CFT build. Versioned — the store key pins exactly
/// what was downloaded.
String chromeForTestingDownloadUrl({
  required final String version,
  required final String platform,
}) =>
    'https://storage.googleapis.com/chrome-for-testing-public/'
    '$version/$platform/chrome-$platform.zip';

/// Chrome-for-testing platform name for this host. Throws
/// [UnsupportedError] on platforms CFT does not ship.
String chromeForTestingPlatform({
  final String? operatingSystem,
  final Abi? abi,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final hostAbi = abi ?? Abi.current();
  switch (os) {
    case 'macos':
      return hostAbi == Abi.macosArm64 ? 'mac-arm64' : 'mac-x64';
    case 'linux':
      // CFT publishes linux64; arm64 Linux has no official CFT build.
      return hostAbi == Abi.linuxArm64 ? 'linux-arm64' : 'linux64';
    case 'windows':
      return 'win64';
    default:
      throw UnsupportedError(
        'chrome-for-testing: no builds published for "$os"',
      );
  }
}

/// Path of the browser binary inside an extracted CFT archive, relative to
/// the extraction root. Pure — golden-testable per platform.
String chromeForTestingBinaryInArchive(final String platform) {
  switch (platform) {
    case 'mac-arm64':
    case 'mac-x64':
      // Path contains real spaces; the lint's adjacent-string heuristic is a
      // false positive here.
      // ignore: missing_whitespace_between_adjacent_strings
      return '$platform/Google Chrome for Testing.app/Contents/MacOS/'
          'Google Chrome for Testing';
    case 'linux64':
      return 'chrome-linux64/chrome';
    case 'linux-arm64':
      return 'chrome-linux-arm64/chrome';
    case 'win64':
      return 'chrome-win64/chrome.exe';
    default:
      throw UnsupportedError(
        'chrome-for-testing: unknown platform "$platform"',
      );
  }
}

/// Provisions and resolves a Chromium binary for browser sessions.
class ChromeForTestingProvisioner {
  ChromeForTestingProvisioner({
    final LocalArtifactStore? store,
    final String? toolsRoot,
    final String? platform,
    final Future<String> Function(Uri url)? fetchText,
    final Future<List<int>> Function(Uri url)? fetchBytes,
  }) : store = store ?? LocalArtifactStore(),
       toolsRoot =
           toolsRoot ?? _defaultToolsRoot(Platform.environment),
       platform = platform ?? chromeForTestingPlatform(),
       fetchText = fetchText ?? _defaultFetchText,
       fetchBytes = fetchBytes ?? _defaultFetchBytes;

  final LocalArtifactStore store;

  /// Extraction root: `<toolsRoot>/<version>-<platform>/…`.
  final String toolsRoot;

  /// CFT platform identifier (e.g. `mac-arm64`).
  final String platform;

  final Future<String> Function(Uri url) fetchText;
  final Future<List<int>> Function(Uri url) fetchBytes;

  static String _defaultToolsRoot(final Map<String, String> env) {
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    return p.join(home, '.oka', 'tools', 'chrome-for-testing');
  }

  static Future<String> _defaultFetchText(final Uri url) async {
    final result = await Process.run('curl', [
      '-L',
      '-f',
      '-s',
      url.toString(),
    ], runInShell: true);
    if (result.exitCode != 0) {
      throw Exception('Failed to fetch $url: ${result.stderr}');
    }
    return result.stdout as String;
  }

  static Future<List<int>> _defaultFetchBytes(final Uri url) async {
    final tmp = await Directory.systemTemp.createTemp('oka_cft_');
    final tempFile = p.join(tmp.path, 'download.bin');
    final result = await Process.run('curl', [
      '-L',
      '-f',
      '-o',
      tempFile,
      url.toString(),
    ], runInShell: true);
    if (result.exitCode != 0) {
      throw Exception('Failed to download $url: ${result.stderr}');
    }
    return File(tempFile).readAsBytes();
  }

  /// Path the browser binary takes once extraction completed for
  /// [version]. Deterministic; used both to check and to produce.
  String binaryPathInToolsRoot(final String version) => p.join(
    toolsRoot,
    '$version-$platform',
    chromeForTestingBinaryInArchive(platform),
  );

  /// An already-provisioned binary, or null. Scans extraction roots (the
  /// version is whatever was provisioned first — no network).
  String? findProvisioned() {
    final root = Directory(toolsRoot);
    if (!root.existsSync()) return null;
    final dirs =
        root.listSync(followLinks: false).whereType<Directory>().toList()
          ..sort((final a, final b) => b.path.compareTo(a.path));
    for (final dir in dirs) {
      final candidate = p.join(
        dir.path,
        chromeForTestingBinaryInArchive(platform),
      );
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Resolves the Stable channel version from the last-known-good manifest.
  Future<String> resolveStableVersion() async {
    final decoded =
        jsonDecode(await fetchText(Uri.parse(kChromeForTestingVersionsUrl)))
            as Map<String, dynamic>;
    final channels = decoded['channels'] as Map<String, dynamic>?;
    final stable = channels?['Stable'] as Map<String, dynamic>?;
    final version = stable?['version'] as String?;
    if (version == null || version.isEmpty) {
      throw Exception(
        'chrome-for-testing manifest has no Stable version: '
        '$kChromeForTestingVersionsUrl',
      );
    }
    return version;
  }

  /// Downloads (or reuses from the artifact store) and extracts the Stable
  /// CFT build. Returns the browser binary path.
  Future<String> provision({final void Function(String message)? log}) async {
    final say = log ?? print;
    final version = await resolveStableVersion();
    final url = chromeForTestingDownloadUrl(version: version, platform: platform);
    final zipFile = await store.fetch(
      ContentKey.compute(
        category: 'chrome-for-testing',
        name: 'chrome',
        version: version,
        inputs: [url],
        platform: platform,
        fileName: 'chrome-$platform.zip',
      ),
      () async {
        say(
          '📥 downloading chrome-for-testing $version ($platform)…',
        );
        final bytes = await fetchBytes(Uri.parse(url));
        final tmp = await Directory.systemTemp.createTemp('oka_cft_');
        return File(p.join(tmp.path, 'chrome-$platform.zip'))
          ..writeAsBytesSync(bytes, flush: true);
      },
    );

    final existing = binaryPathInToolsRoot(version);
    if (File(existing).existsSync()) return existing;
    say('📦 extracting chrome-for-testing $version…');
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    // Entry names already carry the archive's top-level folder (e.g.
    // `chrome-mac-arm64/…`), so extracting under the version dir is enough.
    final versionDir = p.join(toolsRoot, '$version-$platform');
    await Directory(versionDir).create(recursive: true);
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final out = p.join(versionDir, entry.name);
      await File(out).parent.create(recursive: true);
      await File(out).writeAsBytes(entry.content as List<int>, flush: true);
    }
    if (!Platform.isWindows) {
      final binary = File(existing);
      if (binary.existsSync()) {
        await Process.run('chmod', ['+x', existing], runInShell: true);
      }
    }
    if (!File(existing).existsSync()) {
      throw Exception(
        'chrome-for-testing extracted to $versionDir but the browser binary '
        'is missing (expected ${chromeForTestingBinaryInArchive(platform)})',
      );
    }
    say('✅ chrome-for-testing $version ready');
    return existing;
  }

  /// Full resolution order (ADR-0028 §5): explicit → `OKA_CHROME_BIN` →
  /// provisioned → system Chrome → loud provisioning (ADR-0007; suppressed
  /// by `OKA_NO_AUTO_INSTALL=1`, which makes this return null).
  ///
  /// Explicit paths are a hermetic contract: they are returned verbatim
  /// without existence checks — a wrong explicit path must surface as a
  /// spawn failure, never be silently replaced by whatever Chrome the host
  /// happens to have.
  Future<String?> resolveBinary({
    final String? explicitPath,
    final Map<String, String>? environment,
    final void Function(String message)? log,
  }) async {
    final env = environment ?? Platform.environment;
    if (explicitPath != null && explicitPath.trim().isNotEmpty) {
      return explicitPath;
    }
    final envBin = env['OKA_CHROME_BIN']?.trim();
    if (envBin != null && envBin.isNotEmpty) return envBin;
    final provisioned = findProvisioned();
    if (provisioned != null) return provisioned;
    final system = findSystemChrome(environment: env);
    if (system != null) return system;
    if (env['OKA_NO_AUTO_INSTALL'] == '1') return null;
    final say = log ?? print;
    say(
      '🌐 no Chrome binary found — provisioning chrome-for-testing '
      '(escape: OKA_NO_AUTO_INSTALL=1)',
    );
    return provision(log: say);
  }

  /// Well-known system Chrome installs, checked last (the provisioned build
  /// is preferred: version-pinned, store-visible, hermetic).
  String? findSystemChrome({final Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    final candidates = <String>[
      if (Platform.isMacOS)
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      if (Platform.isLinux) ...[
        '/usr/bin/google-chrome',
        '/usr/bin/chromium',
        '/usr/bin/chromium-browser',
      ],
      if (Platform.isWindows) ...[
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        p.join(
          env['LOCALAPPDATA'] ?? p.join(home, 'AppData', 'Local'),
          r'Google\Chrome\Application\chrome.exe',
        ),
      ],
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }
}
