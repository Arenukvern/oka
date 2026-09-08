/// Session manifest / flag parity (ADR-0011 H1).
///
/// At build time the no-Gradle pipeline records `run_session.json` next to
/// the APK ([RecordRunSessionStep]): the Flutter SDK path + engine revision
/// that produced the `flutter_assets`, the target file, build mode, merged
/// dart-defines, application id, and ABIs. `oka dev` later loads the
/// manifest, validates the requested session against it
/// ([RunSession.validateAgainst]), and **refuses loudly on mismatch** — a
/// mismatched attach silently compiles a kernel that corrupts the running
/// app, failing at runtime instead of at command time.
///
/// The flutter binary for the session is always resolved from the recorded
/// SDK path ([flutterBinaryForSdk]) — never ambient `PATH` — so the session
/// uses the exact flutter_tools that produced the APK's kernel.
///
/// ## `run_session.json` format (schema 1)
///
/// ```json
/// {
///   "schema": 1,
///   "oka_version": "0.6.0",
///   "recorded_at": "2026-09-07T12:00:00.000Z",
///   "flutter_sdk_path": "/users/me/fvm/default",
///   "engine_revision": "f88005a259ba379c2c1156178aa1870936be7b7f",
///   "target_file": "lib/main.dart",
///   "build_mode": "debug",
///   "dart_defines": {"STORE": "googlePlay"},
///   "application_id": "dev.example.app",
///   "abis": ["arm64-v8a"],
///   "apk_path": ".oka_cache/build/debug/app-debug.apk",
///   "flavor": "",
///   "track_widget_creation": true
/// }
/// ```
///
/// Written deterministically (sorted dart-define keys, fixed field order),
/// so byte-identical builds produce byte-identical manifests (the
/// `recorded_at` timestamp is the only intentionally volatile field).
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../android_artifacts.dart';
import '../android_state.dart';
import '../build/flutter_assemble.dart' show readFlutterEngineRevision;
import '../build/toolchain.dart';
import 'device_steps.dart' show findNewestBuiltApk;

/// File name of the session manifest, written next to the APK.
const String runSessionFileName = 'run_session.json';

/// Manifest schema version. Bump on any breaking field change; readers
/// refuse unknown-schema manifests with an actionable error.
const int runSessionSchemaVersion = 1;

/// Normalizes dart-defines for recording/comparison: stringified values,
/// whitespace-trimmed keys/values, sorted by key. `--dart-define=STORE=
/// googlePlay` and `--dart-define-from-file` contents must normalize to the
/// same map for flag parity.
Map<String, String> normalizeDartDefines(final Map<String, String> defines) {
  final trimmed = <String, String>{
    for (final e in defines.entries) e.key.trim(): e.value.trim(),
  };
  final keys = trimmed.keys.toList()..sort();
  return {for (final k in keys) k: trimmed[k]!};
}

/// Merges `--dart-define` pairs with `--dart-define-from-file` contents and
/// normalizes the result. Pure (file contents are passed in by the caller).
///
/// `pairs` are raw `KEY=VALUE` strings (later wins on duplicate keys);
/// `fileEntries` are the parsed key/values of a define-from-file JSON map.
Map<String, String> mergeDartDefines({
  final List<String> pairs = const [],
  final Map<String, String> fileEntries = const {},
}) {
  final merged = <String, String>{...fileEntries};
  for (final pair in pairs) {
    final i = pair.indexOf('=');
    if (i <= 0) {
      throw FormatException(
        'Invalid --dart-define "$pair" — expected KEY=VALUE.',
      );
    }
    merged[pair.substring(0, i).trim()] = pair.substring(i + 1).trim();
  }
  return normalizeDartDefines(merged);
}

/// The typed session manifest (ADR-0011 H1).
class RunSession {
  const RunSession({
    required this.flutterSdkPath,
    required this.engineRevision,
    required this.targetFile,
    required this.buildMode,
    required this.dartDefines,
    required this.applicationId,
    required this.abis,
    required this.apkPath,
    this.schema = runSessionSchemaVersion,
    this.okaVersion = '',
    this.recordedAt = '',
    this.flavor = '',
    this.trackWidgetCreation = false,
  });

  /// Parses a manifest, tolerating unknown fields (forward-compatible
  /// readers; writers are the same package that reads).
  factory RunSession.fromJson(final Map<String, dynamic> json) {
    final schema = (json['schema'] as num?)?.toInt() ?? runSessionSchemaVersion;
    if (schema != runSessionSchemaVersion) {
      throw RunSessionException(
        'run_session.json has schema $schema but this oka understands '
        'schema $runSessionSchemaVersion — re-run `oka build apk --debug` '
        'with the current oka to regenerate the manifest.',
      );
    }
    final definesRaw = json['dart_defines'];
    final defines = <String, String>{
      if (definesRaw is Map)
        for (final e in definesRaw.entries) e.key.toString(): e.value.toString(),
    };
    final abisRaw = json['abis'];
    return RunSession(
      schema: schema,
      okaVersion: json['oka_version'] as String? ?? '',
      recordedAt: json['recorded_at'] as String? ?? '',
      flutterSdkPath: json['flutter_sdk_path'] as String? ?? '',
      engineRevision: json['engine_revision'] as String? ?? '',
      targetFile: json['target_file'] as String? ?? '',
      buildMode: json['build_mode'] as String? ?? '',
      dartDefines: normalizeDartDefines(defines),
      applicationId: json['application_id'] as String? ?? '',
      abis: [
        if (abisRaw is List) for (final a in abisRaw) a.toString(),
      ],
      apkPath: json['apk_path'] as String? ?? '',
      flavor: json['flavor'] as String? ?? '',
      trackWidgetCreation: json['track_widget_creation'] as bool? ?? false,
    );
  }

  /// Loads and parses the manifest at [path]. Missing or corrupt manifests
  /// throw [RunSessionException] with the rebuild fix.
  factory RunSession.load(final String path) {
    final f = File(path);
    if (!f.existsSync()) {
      throw RunSessionException(
        'No session manifest at $path. Rebuild with the manifest-emitting '
        'oka pipeline: `oka build apk --debug`.',
      );
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw RunSessionException(
        'Corrupt session manifest at $path ($e). Re-run '
        '`oka build apk --debug` to regenerate it.',
      );
    }
    return RunSession.fromJson(json);
  }

  /// Finds the manifest for [apkPath] (same directory, fixed name), or null
  /// when none was recorded (pre-H1 build).
  static RunSession? forApk(final String apkPath) {
    final manifest = p.join(p.dirname(apkPath), runSessionFileName);
    if (!File(manifest).existsSync()) return null;
    return RunSession.load(manifest);
  }

  final int schema;
  final String okaVersion;
  final String recordedAt;
  final String flutterSdkPath;
  final String engineRevision;
  final String targetFile;
  final String buildMode;

  /// Merged, normalized dart-defines (see [normalizeDartDefines]).
  final Map<String, String> dartDefines;
  final String applicationId;
  final List<String> abis;
  final String apkPath;
  final String flavor;
  final bool trackWidgetCreation;

  /// Deterministic JSON: fields in a fixed order, define keys sorted via
  /// [normalizeDartDefines] (const-constructed sessions included).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': schema,
        'oka_version': okaVersion,
        'recorded_at': recordedAt,
        'flutter_sdk_path': flutterSdkPath,
        'engine_revision': engineRevision,
        'target_file': targetFile,
        'build_mode': buildMode,
        'dart_defines': normalizeDartDefines(dartDefines),
        'application_id': applicationId,
        'abis': abis,
        'apk_path': apkPath,
        'flavor': flavor,
        'track_widget_creation': trackWidgetCreation,
      };

  /// Canonical serialization used both for writing and for golden tests.
  String encode() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  /// Writes the manifest to [path] (parent dirs created).
  Future<File> write(final String path) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    return f.writeAsString('${encode()}\n', flush: true);
  }
}

/// The requested session — what `oka dev` was asked to run. Only fields a
/// user can express on the CLI are compared; unset fields (null) are
/// "no request" and match anything.
class RunSessionRequest {
  const RunSessionRequest({
    this.targetFile,
    this.buildMode,
    this.dartDefines,
    this.applicationId,
  });

  /// `--target` (or the project default when the CLI layer passes one).
  final String? targetFile;

  /// Requested build mode (`oka dev` only ever requests debug — H3 refuses
  /// profile/release; the field exists so the refusal can name the record).
  final String? buildMode;

  /// Merged, normalized defines from `--dart-define` /
  /// `--dart-define-from-file`.
  final Map<String, String>? dartDefines;

  final String? applicationId;

  /// Normalized view for comparison.
  Map<String, String>? get normalizedDefines => dartDefines == null
      ? null
      : normalizeDartDefines(dartDefines!);
}

/// One differing field between the recorded manifest and the request.
class SessionFieldMismatch {
  const SessionFieldMismatch({
    required this.field,
    required this.recorded,
    required this.requested,
    required this.fix,
  });

  /// Manifest/request field name (matches the JSON key).
  final String field;
  final String recorded;
  final String requested;

  /// The actionable fix (rebuild vs align flags).
  final String fix;

  @override
  String toString() =>
      '  - $field: recorded "$recorded", requested "$requested"\n'
      '    fix: $fix';
}

/// Validation result: [ok] or [mismatches] (oka-branded rendering via
/// [formatSessionMismatches]).
class SessionValidation {
  const SessionValidation.ok(this.session) : mismatches = const [];

  const SessionValidation.invalid(this.mismatches) : session = null;

  final RunSession? session;
  final List<SessionFieldMismatch> mismatches;

  bool get ok => mismatches.isEmpty;
}

/// Validates a [request] against a recorded [session]. Never
/// warn-and-continue: mismatches come back typed so the caller can refuse
/// loudly.
SessionValidation validateRunSession(
  final RunSession session,
  final RunSessionRequest request,
) {
  final mismatches = <SessionFieldMismatch>[];
  const String rebuild = 'rebuild: `oka build apk --debug` with these flags';
  const String align = 'align the `oka dev` flags with the recorded build';

  String? of(final String? v) => (v == null || v.isEmpty) ? null : v;

  final String? target = of(request.targetFile);
  if (target != null && target != session.targetFile) {
    mismatches.add(
      SessionFieldMismatch(
        field: 'target_file',
        recorded: session.targetFile,
        requested: target,
        fix: align,
      ),
    );
  }
  final String? mode = of(request.buildMode);
  if (mode != null && mode != session.buildMode) {
    mismatches.add(
      SessionFieldMismatch(
        field: 'build_mode',
        recorded: session.buildMode,
        requested: mode,
        fix: mode == 'debug'
            ? rebuild
            : 'hot reload is debug-only (ADR-0011 §5); use `oka build apk '
                '--debug` and attach to that',
      ),
    );
  }
  final Map<String, String>? defines = request.normalizedDefines;
  if (defines != null && !mapEqualsStr(defines, session.dartDefines)) {
    final differing = <String>{
      ...defines.keys.where(
        (final k) => session.dartDefines[k] != defines[k],
      ),
      ...session.dartDefines.keys.where((final k) => !defines.containsKey(k)),
    }.toList()
      ..sort();
    mismatches.add(
      SessionFieldMismatch(
        field: 'dart_defines (${differing.join(', ')})',
        recorded: definesToLine(session.dartDefines),
        requested: definesToLine(defines),
        fix: align,
      ),
    );
  }
  final String? appId = of(request.applicationId);
  if (appId != null && appId != session.applicationId) {
    mismatches.add(
      SessionFieldMismatch(
        field: 'application_id',
        recorded: session.applicationId,
        requested: appId,
        fix: align,
      ),
    );
  }
  return mismatches.isEmpty
      ? SessionValidation.ok(session)
      : SessionValidation.invalid(mismatches);
}

/// Oka-branded mismatch error: names every differing field + the fix.
String formatSessionMismatches(final List<SessionFieldMismatch> mismatches) =>
    '❌ Session mismatch — refusing to start a dev session against this '
    'APK.\n'
    '   A mismatched attach compiles a kernel the running app cannot '
    'accept\n'
    '   (it fails at runtime, not at command time).\n'
    '${mismatches.map((final m) => m.toString()).join('\n')}\n'
    '\n'
    '   The recorded session lives in run_session.json next to the APK.';

bool mapEqualsStr(final Map<String, String> a, final Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

String definesToLine(final Map<String, String> defines) =>
    defines.entries.map((final e) => '${e.key}=${e.value}').join(', ');

/// Thrown for missing/corrupt/unknown-schema manifests (fail closed).
class RunSessionException implements Exception {
  RunSessionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Result of the `oka dev` preflight ([checkDevSession]): printable status
/// lines, or the refusal reason. The CLI layer stays parse-and-delegate —
/// every bit of session logic lives here.
class DevSessionCheck {
  const DevSessionCheck.ok(this.lines, this.session)
    : refusal = null;

  const DevSessionCheck.refused(this.refusal)
    : lines = const [],
      session = null;

  final List<String> lines;
  final RunSession? session;
  final String? refusal;

  bool get ok => refusal == null;
}

/// `oka dev` preflight (ADR-0011 H1): validate the newest built APK's
/// session manifest against the requested session and resolve the flutter
/// binary from the recorded SDK path (never ambient PATH).
///
/// Refusals (never warn-and-continue):
/// * no APK / no manifest → rebuild instructions;
/// * flag mismatch (target / defines / build mode / app id) →
///   oka-branded error naming every differing field + the fix;
/// * engine revision drift (SDK upgraded under the recorded path since the
///   build) → rebuild instructions;
/// * recorded SDK path no longer holds a flutter binary.
Future<DevSessionCheck> checkDevSession({
  required final String projectPath,
  final String? targetFile,
  final List<String> dartDefinePairs = const [],
  final String? dartDefineFromFile,
  final String requestedBuildMode = 'debug',
}) async {
  final apk = await findNewestBuiltApk(projectPath);
  if (apk == null) {
    return const DevSessionCheck.refused(
      'No built APK found under .oka_cache/build/.\n'
      '   fix: run `oka build apk --debug` first — oka dev attaches to an '
      'oka-built debug APK only.',
    );
  }
  final session = RunSession.forApk(apk);
  if (session == null) {
    return DevSessionCheck.refused(
      'The newest APK has no session manifest (built before oka recorded '
      'run_session.json): $apk\n'
      '   fix: run `oka build apk --debug` to rebuild with flag-parity '
      'recording.',
    );
  }

  // Merge requested defines (CLI pairs + define-from-file).
  Map<String, String> fileEntries = const {};
  if (dartDefineFromFile != null) {
    final f = File(dartDefineFromFile);
    if (!f.existsSync()) {
      return DevSessionCheck.refused(
        '--dart-define-from-file not found: $dartDefineFromFile',
      );
    }
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map) {
        return const DevSessionCheck.refused(
          '--dart-define-from-file must contain a JSON object of '
          'KEY: VALUE pairs.',
        );
      }
      fileEntries = decoded.map(
        (final k, final v) => MapEntry(k.toString(), v.toString()),
      );
    } on FormatException catch (e) {
      return DevSessionCheck.refused(
        '--dart-define-from-file is not valid JSON: $e',
      );
    }
  }
  Map<String, String>? requestedDefines;
  if (dartDefinePairs.isNotEmpty || fileEntries.isNotEmpty) {
    requestedDefines = mergeDartDefines(
      pairs: dartDefinePairs,
      fileEntries: fileEntries,
    );
  }

  final validation = validateRunSession(
    session,
    RunSessionRequest(
      targetFile: targetFile,
      buildMode: requestedBuildMode,
      dartDefines: requestedDefines,
    ),
  );
  if (!validation.ok) {
    return DevSessionCheck.refused(formatSessionMismatches(
      validation.mismatches,
    ));
  }

  // The session must run on the SDK that produced the APK's kernel. If the
  // SDK at the recorded path was upgraded since the build, refuse.
  final currentRevision = await readEngineRevisionFromSdk(
    session.flutterSdkPath,
  );
  if (session.engineRevision.isNotEmpty &&
      currentRevision.isNotEmpty &&
      currentRevision != session.engineRevision) {
    return DevSessionCheck.refused(
      'The Flutter SDK at the recorded path changed since the build '
      '(recorded engine ${session.engineRevision.substring(0, 12)}, now '
      '${currentRevision.substring(0, 12)}).\n'
      '   fix: run `oka build apk --debug` to rebuild against the current '
      'SDK.',
    );
  }

  final binary = flutterBinaryForSdk(session.flutterSdkPath);
  if (!binary.exists) {
    return DevSessionCheck.refused(
      'The recorded Flutter SDK has no flutter binary: '
      '${binary.path}\n'
      '   fix: reinstall the SDK (fvm/flutter install) or re-run '
      '`oka build apk --debug` against the SDK you intend to use.',
    );
  }

  final sessionLine = '🧾 Session: target=${session.targetFile} '
      'mode=${session.buildMode}, '
      'engine ${session.engineRevision.substring(0, 12)}';
  return DevSessionCheck.ok(
    [
      '📱 APK: $apk',
      sessionLine,
      '🛠  Flutter SDK: ${session.flutterSdkPath}',
      ' ↔ flutter binary: ${binary.path}',
      if (requestedDefines != null && requestedDefines.isNotEmpty)
        '🏷  Defines: ${definesToLine(requestedDefines)}',
    ],
    session,
  );
}

/// The flutter binary of the SDK recorded in the manifest — the session
/// must use the SDK that produced the APK's `flutter_assets`, never ambient
/// PATH. Returns the platform-appropriate binary path; [exists] reports
/// whether it is actually present.
({String path, bool exists}) flutterBinaryForSdk(final String flutterSdkPath) {
  final binary = p.join(
    flutterSdkPath,
    'bin',
    'flutter${Platform.isWindows ? '.bat' : ''}',
  );
  return (path: binary, exists: File(binary).existsSync());
}

/// Reads the engine revision for a Flutter SDK **without running flutter**:
/// `<sdk>/bin/internal/engine.version` is authoritative and stable. Falls
/// back to `flutter --version --machine` via the SDK's own binary (never
/// PATH) when the file is absent (older SDK layouts).
Future<String> readEngineRevisionFromSdk(final String flutterSdkPath) async {
  final versionFile = File(
    p.join(flutterSdkPath, 'bin', 'internal', 'engine.version'),
  );
  if (versionFile.existsSync()) {
    return versionFile.readAsStringSync().trim();
  }
  final binary = flutterBinaryForSdk(flutterSdkPath);
  if (!binary.exists) return '';
  final viaTool = await readFlutterEngineRevision(
    runProcess: (
      final executable,
      final args,
    ) => Process.run(binary.path, args),
  );
  return viaTool ?? '';
}

/// Records `run_session.json` next to the packaged artifact (APK/AAB) at
/// the end of the no-Gradle pipelines (ADR-0011 H1).
///
/// Requires `apkPath` (the final artifact, already provided by
/// `package-and-sign` / `package-and-sign-aab`); provides
/// [runSessionPath]. Flutter SDK path + engine revision resolve through the
/// [ResolvedToolchain] policy (explicit config wins) so the manifest records
/// exactly what built the kernel.
class RecordRunSessionStep extends BuildStep {
  RecordRunSessionStep({this.toolchain, this.flutterSdkPathOverride});

  /// Null → [PipelineState.resolvedToolchain] → default policy.
  final ResolvedToolchain? toolchain;

  /// Injectable Flutter SDK path (tests / explicit config).
  final String? flutterSdkPathOverride;

  @override
  String get name => 'record-run-session';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Set<Artifact<Object>> get provides => {runSessionPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final artifactPath = state.apkPath;
    if (artifactPath == null || artifactPath.isEmpty) {
      return StepResult.failure(
        'record-run-session: no packaged artifact in state — this step must '
        'run after package-and-sign.',
      );
    }
    final String flutterSdk;
    if (flutterSdkPathOverride != null) {
      flutterSdk = flutterSdkPathOverride!;
    } else {
      try {
        flutterSdk = await (toolchain ??
                state.resolvedToolchain ??
                ResolvedToolchain())
            .findFlutterSdk();
      } on ToolchainException catch (e) {
        return StepResult.failure(
          'record-run-session: could not resolve the Flutter SDK that built '
          'this artifact — $e',
        );
      }
    }
    final engineRevision = await readEngineRevisionFromSdk(flutterSdk);
    final manifest = RunSession(
      flutterSdkPath: flutterSdk,
      engineRevision: engineRevision,
      targetFile: ctx.entrypoint,
      buildMode: ctx.mode.name,
      dartDefines: normalizeDartDefines(ctx.dartDefines),
      applicationId: ctx.config.android.applicationId,
      abis: state.abis,
      apkPath: artifactPath,
      flavor: ctx.flavor,
      trackWidgetCreation: ctx.mode.isDebug,
      recordedAt: DateTime.now().toUtc().toIso8601String(),
    );
    final manifestPath = p.join(p.dirname(artifactPath), runSessionFileName);
    try {
      await manifest.write(manifestPath);
    } on IOException catch (e) {
      return StepResult.failure(
        'record-run-session: failed to write $manifestPath — $e',
      );
    }
    state['run_session_path'] = manifestPath;
    if (ctx.verbose) {
      print('🧾 Recorded session manifest: $manifestPath');
    }
    return StepResult.success({runSessionPath.id: manifestPath});
  }
}
