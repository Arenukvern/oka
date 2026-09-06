import 'dart:io';
import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import '../../android_state.dart';

/// Extra asset sources merged into `flutter_assets/` at staging time.
///
/// Covers cases pubspec assets don't: generated files, raw config, local
/// bundles, per-flavor overrides. Configured via `oka.yaml`:
///
/// ```yaml
/// pipeline:
///   extra_assets:
///     - from: build/generated/strings
///       to: generated          # → flutter_assets/generated/**
///     - from: config/deeplinks.json
///       to: deeplinks.json     # single file at flutter_assets root
/// ```
class ExtraAssetsStep extends BuildStep {

  ExtraAssetsStep(this.entries);
  /// `from` (project-relative file or dir) → `to` (flutter_assets-relative).
  final List<({String from, String to})> entries;

  @override
  String get name => 'extra-assets';

  /// Parses `pipeline.extra_assets` entries from decoded oka.yaml maps.
  static List<({String from, String to})> parse(final List<dynamic> raw) {
    final out = <({String from, String to})>[];
    for (final e in raw) {
      if (e is Map) {
        final from = e['from']?.toString() ?? '';
        final to = e['to']?.toString() ?? '';
        if (from.isEmpty) continue;
        out.add((from: from, to: to.isEmpty ? p.basename(from) : to));
      } else if (e != null) {
        // Bare string: copy file/dir under its own basename.
        final s = e.toString();
        out.add((from: s, to: p.basename(s)));
      }
    }
    return out;
  }

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    // ADR-0010: constructor entries win; pipeline-level overrides fill in.
    final effective = entries.isNotEmpty
        ? entries
        : (state.pipelineOverrides?.extraAssets ?? const []);
    if (effective.isEmpty) return StepResult.success();
    final assetsDir = state.flutterAssetsDir;
    if (assetsDir == null) {
      return StepResult.failure(
        'extra-assets: flutter_assets not staged yet — this step must run '
        'after flutter-assemble.',
      );
    }
    for (final entry in effective) {
      final src = File(p.join(ctx.projectPath, entry.from));
      final srcDir = Directory(p.join(ctx.projectPath, entry.from));
      final dest = p.join(assetsDir, entry.to);

      if (await src.exists()) {
        await File(dest).parent.create(recursive: true);
        await src.copy(dest);
      } else if (await srcDir.exists()) {
        await _copyTree(srcDir, Directory(dest));
      } else {
        return StepResult.failure(
          'extra-assets: source "${entry.from}" not found in project.',
        );
      }
      if (ctx.verbose) print('   extra asset: ${entry.from} → $entry.to');
    }
    return StepResult.success();
  }

  Future<void> _copyTree(final Directory source, final Directory dest) async {
    await dest.create(recursive: true);
    await for (final e in source.list(recursive: true, followLinks: false)) {
      final rel = p.relative(e.path, from: source.path);
      final out = p.join(dest.path, rel);
      if (e is Directory) {
        await Directory(out).create(recursive: true);
      } else if (e is File) {
        await File(out).parent.create(recursive: true);
        await e.copy(out);
      }
    }
  }
}

/// Generates Android deeplink intent-filter XML fragments from config.
///
/// Configured via `oka.yaml`:
///
/// ```yaml
/// pipeline:
///   deeplinks:
///     - scheme: https
///       host: example.com
///       pathPrefix: /app
/// ```
///
/// Each entry becomes an `<intent-filter>` on MainActivity in the generated
/// manifest. Runs as part of host codegen when entries are present.
class DeeplinkConfig {

  const DeeplinkConfig({
    required this.scheme,
    required this.host,
    this.pathPrefix = '',
  });
  final String scheme;
  final String host;
  final String pathPrefix;

  static DeeplinkConfig? fromMap(final Map<dynamic, dynamic> map) {
    final scheme = map['scheme']?.toString() ?? '';
    // host is optional: custom-scheme deeplinks (e.g. myapp://callback)
    // have no host; https deeplinks require one.
    final host = map['host']?.toString() ?? '';
    if (scheme.isEmpty) return null;
    return DeeplinkConfig(
      scheme: scheme,
      host: host,
      pathPrefix: map['pathPrefix']?.toString() ?? '',
    );
  }

  /// AndroidManifest.xml intent-filter fragment for this deeplink.
  String get intentFilterXml {
    final dataAttrs = StringBuffer()..write('android:scheme="$scheme"');
    if (host.isNotEmpty) {
      dataAttrs.write('\n                android:host="$host"');
    }
    if (pathPrefix.isNotEmpty) {
      dataAttrs.write('\n                android:pathPrefix="$pathPrefix"');
    }
    return '''
            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data
                    $dataAttrs />
            </intent-filter>''';
  }

  static List<DeeplinkConfig> parse(final List<dynamic> raw) {
    final out = <DeeplinkConfig>[];
    for (final e in raw) {
      if (e is Map) {
        final c = DeeplinkConfig.fromMap(e);
        if (c != null) out.add(c);
      }
    }
    return out;
  }
}
