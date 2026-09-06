import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:yaml/yaml.dart';

import 'pipeline/steps/asset_steps.dart' show ExtraAssetsStep;
import 'build/launcher_icon.dart';
import 'manifest_spec.dart';
import 'pipeline/steps/asset_steps.dart' show DeeplinkConfig;
import 'signing_config.dart';

/// Fast-settings parsed from `oka.yaml` `pipeline:` section.
///
/// Precedence: built-in defaults < `oka.yaml` pipeline section < Dart
/// composition (a user-supplied [Pipeline] always wins).
class PipelineOverrides {
  /// Extra Maven coordinates (`group:artifact:version`) merged into the
  /// runtime dependency set. The main escape hatch for missing-dependency
  /// gaps without editing oka.
  final List<String> extraDeps;

  /// Extra asset sources merged into flutter_assets (files or dirs).
  final List<({String from, String to})> extraAssets;

  /// Deeplink declarations rendered as manifest intent-filters.
  final List<DeeplinkConfig> deeplinks;

  /// Launcher icon configuration (adaptive, vector-first).
  final IconConfig icon;

  /// Local AAR files (project-relative paths) to package into the APK.
  final List<String> localAars;

  /// Resource qualifier filter (aapt2 `--configs`), e.g. `['en', 'ru']`.
  final List<String> resourceConfigs;

  /// Release signing configuration (null → key.properties → debug fallback).
  final SigningConfig? signing;

  /// Typed manifest override (ADR-0006). Null → YAML `android.manifest:`
  /// only; non-null wins over YAML.
  final ManifestSpec? manifest;

  /// User Android res dirs (project-relative) merged into the generated
  /// res tree before aapt2 (launch themes, styles, splash drawables,
  /// mipmap icons). Parsed from `android.res_dirs`.
  final List<String> resDirs;

  /// Plugins excluded from packaging (e.g. test-only `integration_test`).
  final List<String> excludePlugins;

  /// Artifact size budget in MB — post-build lint fails when exceeded.
  final int? maxSizeMb;

  const PipelineOverrides({
    this.extraDeps = const [],
    this.extraAssets = const [],
    this.deeplinks = const [],
    this.icon = const IconConfig(),
    this.localAars = const [],
    this.resourceConfigs = const [],
    this.signing,
    this.manifest,
    this.resDirs = const [],
    this.excludePlugins = const [],
    this.maxSizeMb,
  });

  /// Typed-override helper for Dart composition (ADR-0006). Example:
  /// `overrides.copyWith(resourceConfigs: ['en', 'ru'])`.
  PipelineOverrides copyWith({
    List<String>? extraDeps,
    List<({String from, String to})>? extraAssets,
    List<DeeplinkConfig>? deeplinks,
    IconConfig? icon,
    List<String>? localAars,
    List<String>? resourceConfigs,
    SigningConfig? signing,
    ManifestSpec? manifest,
    List<String>? resDirs,
    List<String>? excludePlugins,
    int? maxSizeMb,
  }) => PipelineOverrides(
    extraDeps: extraDeps ?? this.extraDeps,
    extraAssets: extraAssets ?? this.extraAssets,
    deeplinks: deeplinks ?? this.deeplinks,
    icon: icon ?? this.icon,
    localAars: localAars ?? this.localAars,
    resourceConfigs: resourceConfigs ?? this.resourceConfigs,
    signing: signing ?? this.signing,
    manifest: manifest ?? this.manifest,
    resDirs: resDirs ?? this.resDirs,
    excludePlugins: excludePlugins ?? this.excludePlugins,
    maxSizeMb: maxSizeMb ?? this.maxSizeMb,
  );

  factory PipelineOverrides.fromYamlMap(Map<dynamic, dynamic> map) {
    final deps = map['extra_deps'];
    final assetsRaw = map['extra_assets'];
    final linksRaw = map['deeplinks'];
    final iconRaw = map['icon'];
    final aarsRaw = map['local_aars'];
    return PipelineOverrides(
      extraDeps: deps is List ? deps.map((e) => e.toString()).toList() : [],
      extraAssets: assetsRaw is List
          ? ExtraAssetsStep.parse(assetsRaw)
          : const [],
      deeplinks: linksRaw is List ? DeeplinkConfig.parse(linksRaw) : const [],
      icon: iconRaw is Map ? IconConfig.fromMap(iconRaw) : const IconConfig(),
      localAars: aarsRaw is List
          ? aarsRaw.map((e) => e.toString()).toList()
          : const [],
      resourceConfigs: _resourceConfigs(map['resource_configs']),
      excludePlugins:
          map['exclude_plugins'] is List
          ? (map['exclude_plugins'] as List).map((e) => e.toString()).toList()
          : const [],
      maxSizeMb: map['max_size_mb'] is int ? map['max_size_mb'] as int : null,
    );
  }

  /// Merges `android:` section surfaces that are not `pipeline:`-scoped.
  static PipelineOverrides fromOkaYaml(Map<dynamic, dynamic> doc) {
    final pipelineRaw = doc['pipeline'];
    final base = pipelineRaw is Map
        ? PipelineOverrides.fromYamlMap(pipelineRaw)
        : const PipelineOverrides();
    final android = doc['android'];
    final resRaw = android is Map ? android['res_dirs'] : null;
    final resDirs = resRaw is List
        ? resRaw.map((e) => e.toString()).toList(growable: false)
        : const <String>[];
    return resDirs.isEmpty ? base : base.copyWith(resDirs: resDirs);
  }


  static List<String> _resourceConfigs(dynamic raw) =>
      raw is List ? raw.map((e) => e.toString()).toList() : const [];

  static Future<PipelineOverrides> load(String projectPath) async {
    final file = File(p.join(projectPath, 'oka.yaml'));
    if (!await file.exists()) return const PipelineOverrides();
    try {
      final doc = loadYaml(await file.readAsString());
      if (doc is! Map) return const PipelineOverrides();
      return PipelineOverrides.fromOkaYaml(Map<dynamic, dynamic>.from(doc));
    } on YamlException {
      return const PipelineOverrides();
    }
  }
}
