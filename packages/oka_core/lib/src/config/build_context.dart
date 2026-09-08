import 'package:from_json_to_json/from_json_to_json.dart';

import '../pipeline_events.dart';
import '../process_runner.dart';
import 'oka_config.dart';

/// Build mode enumeration.
enum BuildMode {
  debug,
  release,
  profile;

  /// Convenience predicate.
  bool get isDebug => this == BuildMode.debug;

  /// Convenience predicate.
  bool get isRelease => this == BuildMode.release;

  /// Convenience predicate.
  bool get isProfile => this == BuildMode.profile;
}

/// Typed build context passed to every [BuildStep] (ADR-0006).
///
/// One immutable value per build: paths, mode, merged configuration, and
/// SDK locations. Steps never mutate it — derived values go through
/// [copyWith], and derived state (artifact outputs) lives in the pipeline's
/// `PipelineState` instead.
///
/// ```dart
/// @override
/// Future<StepResult> run(BuildContext ctx, PipelineState state) async {
///   final out = File('${ctx.buildDir}/staged/app.apk');
///   if (ctx.mode == BuildMode.release) {
///     out.createSync(recursive: true);
///   }
///   return StepResult.success();
/// }
/// ```
///
/// Configuration precedence (highest wins): code defaults < `oka.yaml` <
/// typed Dart config ([Oka] `configOverrides`) < CLI args.
///
/// Immutable value: configuration enters via constructors / [copyWith], never
/// by mutating a map mid-build. JSON is parsed only at this boundary
/// (CLI args / oka.yaml) — steps see typed getters.
class BuildContext {

  const BuildContext({
    required this.projectPath,
    required this.buildDir,
    required this.mode,
    required this.config,
    this.cacheDir = '',
    this.tempDir = '',
    this.flutterSdkPath = '',
    this.androidSdkPath = '',
    this.verbose = false,
    this.flavor = '',
    this.targetAbi = '',
    this.buildAab = false,
    this.verifyAab = false,
    this.dartDefines = const {},
    this.targetOverride = '',
    this.buildTimestamp,
    this.processRunner,
    this.onEvent,
  });

  /// Decodes from the runner/CLI context payload (unknown mode strings
  /// fall back to [BuildMode.debug]).
  factory BuildContext.fromJson(final Object? json) {
    final map = jsonDecodeMap(json);
    final modeStr = jsonDecodeString(map['mode']);
    return BuildContext(
      projectPath: jsonDecodeString(map['project_path']),
      buildDir: jsonDecodeString(map['build_dir']),
      mode: switch (modeStr) {
        'release' => BuildMode.release,
        'profile' => BuildMode.profile,
        _ => BuildMode.debug,
      },
      config: OkaConfig.fromJson(map['config']),
      cacheDir: jsonDecodeString(map['cache_dir']),
      tempDir: jsonDecodeString(map['temp_dir']),
      flutterSdkPath: jsonDecodeString(map['flutter_sdk_path']),
      androidSdkPath: jsonDecodeString(map['android_sdk_path']),
      verbose: jsonDecodeBool(map['verbose']),
      flavor: jsonDecodeString(map['flavor']),
      targetAbi: jsonDecodeString(map['target_abi']),
      buildAab: jsonDecodeBool(map['build_aab']),
      verifyAab: jsonDecodeBool(map['verify_aab']),
      dartDefines: _decodeDefines(map['dart_defines']),
      targetOverride: jsonDecodeString(map['target_override']),
      buildTimestamp: dateTimeFromMillisecondsSinceEpoch(
        jsonDecodeInt(map['build_timestamp']),
      ),
    );
  }
  /// Project root path.
  final String projectPath;

  /// Build output directory.
  final String buildDir;

  /// Build mode (debug, release, profile).
  final BuildMode mode;

  /// Oka configuration from oka.yaml.
  final OkaConfig config;

  /// Cache directory for incremental builds.
  final String cacheDir;

  /// Temporary directory for intermediate build artifacts.
  final String tempDir;

  /// Flutter SDK path (empty = auto-locate).
  final String flutterSdkPath;

  /// Android SDK path (empty = auto-locate).
  final String androidSdkPath;

  /// Whether verbose logging is enabled.
  final bool verbose;

  /// Build flavor (if using flavors).
  final String flavor;

  /// Target device ABI (empty = all configured ABIs).
  final String targetAbi;

  /// Whether to build an Android App Bundle instead of an APK.
  final bool buildAab;

  /// After a successful AAB build, verify it with bundletool
  /// (`build-apks --mode=universal`) — the same parsing path as Play.
  final bool verifyAab;

  /// Dart defines (`--dart-define`) merged with
  /// `--dart-define-from-file` contents. Passed to `flutter assemble`.
  final Map<String, String> dartDefines;

  /// Flutter entrypoint override (`--target`); empty = use
  /// [OkaConfig.flutter] entrypoint.
  final String targetOverride;

  /// Build timestamp.
  final DateTime? buildTimestamp;

  /// Injectable process runner (tests substitute fakes; default null →
  /// [SystemProcessRunner] via [runner]).
  final ProcessRunner? processRunner;

  /// Pipeline event sink (null → events dropped; CLI pipes to stdout).
  final void Function(PipelineEvent event)? onEvent;

  static Map<String, String> _decodeDefines(final Object? raw) {
    if (raw is Map) {
      return raw.map((final k, final v) => MapEntry(k.toString(), v.toString()));
    }
    return const {};
  }

  /// Process runner resolved against the injected instance (if any).
  ProcessRunner get runner => processRunner ?? const SystemProcessRunner();

  /// Emits a progress message as a [PipelineLog] event.
  void log(final String message) => onEvent?.call(PipelineLog(message));

  /// Emits a [BuildWarning] — does not fail the build.
  void warn(final String message) => onEvent?.call(BuildWarning(message));

  /// Effective Flutter entrypoint: [targetOverride] wins over oka.yaml.
  String get entrypoint => targetOverride.isNotEmpty
      ? targetOverride
      : config.flutter.entrypoint.isEmpty
      ? 'lib/main.dart'
      : config.flutter.entrypoint;

  /// Encodes back to the runner/CLI context payload.
  Map<String, dynamic> toJson() => {
    'project_path': projectPath,
    'build_dir': buildDir,
    'mode': mode.name,
    'config': config.toJson(),
    'cache_dir': cacheDir,
    'temp_dir': tempDir,
    'flutter_sdk_path': flutterSdkPath,
    'android_sdk_path': androidSdkPath,
    'verbose': verbose,
    'flavor': flavor,
    'target_abi': targetAbi,
    'build_aab': buildAab,
    'verify_aab': verifyAab,
    'dart_defines': dartDefines,
    'target_override': targetOverride,
    'build_timestamp': buildTimestamp?.millisecondsSinceEpoch ?? 0,
  };

  BuildContext copyWith({
    final ProcessRunner? processRunner,
    final void Function(PipelineEvent event)? onEvent,
    final String? projectPath,
    final String? buildDir,
    final BuildMode? mode,
    final OkaConfig? config,
    final String? cacheDir,
    final String? tempDir,
    final String? flutterSdkPath,
    final String? androidSdkPath,
    final bool? verbose,
    final String? flavor,
    final String? targetAbi,
    final bool? buildAab,
    final bool? verifyAab,
    final Map<String, String>? dartDefines,
    final String? targetOverride,
    final DateTime? buildTimestamp,
  }) => BuildContext(
    projectPath: projectPath ?? this.projectPath,
    buildDir: buildDir ?? this.buildDir,
    mode: mode ?? this.mode,
    config: config ?? this.config,
    cacheDir: cacheDir ?? this.cacheDir,
    tempDir: tempDir ?? this.tempDir,
    flutterSdkPath: flutterSdkPath ?? this.flutterSdkPath,
    androidSdkPath: androidSdkPath ?? this.androidSdkPath,
    verbose: verbose ?? this.verbose,
    flavor: flavor ?? this.flavor,
    targetAbi: targetAbi ?? this.targetAbi,
    buildAab: buildAab ?? this.buildAab,
    verifyAab: verifyAab ?? this.verifyAab,
    dartDefines: dartDefines ?? this.dartDefines,
    targetOverride: targetOverride ?? this.targetOverride,
    buildTimestamp: buildTimestamp ?? this.buildTimestamp,
  );

  static const empty = BuildContext(
    projectPath: '',
    buildDir: '',
    mode: BuildMode.debug,
    config: OkaConfig.empty,
  );
}

/// Extension type for build artifacts.
extension type const BuildArtifact(Map<String, dynamic> value) {
  /// Decodes from the artifact payload map.
  factory BuildArtifact.fromJson(final Object? json) =>
      BuildArtifact(jsonDecodeMap(json));

  /// Output file path (APK or AAB).
  String get apkPath => jsonDecodeString(value['apk_path']);

  /// Output file path (APK or AAB).
  String get outputPath => jsonDecodeString(value['apk_path']);

  /// File size in bytes.
  int get size => jsonDecodeInt(value['size']);

  /// Build duration in milliseconds.
  int get buildDuration => jsonDecodeInt(value['build_duration']);

  /// Build timestamp.
  DateTime? get timestamp =>
      dateTimeFromMillisecondsSinceEpoch(jsonDecodeInt(value['timestamp']));

  /// Whether this is a successful build.
  bool get success => jsonDecodeBool(value['success']);

  /// Error message if build failed.
  String get error => jsonDecodeString(value['error']);

  /// Encodes back to the payload map (identity).
  Map<String, dynamic> toJson() => value;

  static const empty = BuildArtifact({});
}
