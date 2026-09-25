import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:yaml/yaml.dart';

import 'composition.dart';
import 'config/build_context.dart';
import 'config/oka_config.dart';
import 'pipeline/pipeline.dart';
import 'publish/publish_target.dart';
import 'session_state_manager.dart';
import 'session_state_reconciler.dart';
import 'session_state_registry.dart';
import 'store/cache_projects.dart';
import 'target_execution_scope.dart';
import 'targets/describe.dart';
import 'targets/target.dart';

/// Entry-point options accepted by [okaRun] (forwarded by `oka build` when a
/// project declares `pipeline.dart_entrypoint` in oka.yaml).
final _okaRunParser = ArgParser()
  ..addFlag('release', negatable: false, help: 'Build release variant')
  ..addFlag('debug', negatable: false, help: 'Build debug variant (default)')
  ..addFlag('profile', negatable: false, help: 'Build profile variant')
  ..addFlag('aab', negatable: false, help: 'Build AAB instead of APK')
  ..addFlag(
    'verify-aab',
    negatable: false,
    help: 'Verify the produced AAB with bundletool (build-apks universal)',
  )
  ..addFlag('verbose', abbr: 'v', negatable: false)
  ..addOption('platform', defaultsTo: 'android')
  ..addOption('flavor', defaultsTo: '')
  ..addOption('abi', defaultsTo: '')
  ..addOption('target', help: 'Flutter entrypoint (e.g. lib/main_prod.dart)')
  ..addMultiOption('dart-define')
  ..addOption('dart-define-from-file')
  // ADR-0010: print the fully merged config map (oka.yaml + typed Dart
  // config) as JSON and exit — used by tooling (e.g. `oka debug step`) to
  // materialize a hook project's config without running a build.
  ..addFlag('print-config', negatable: false, hide: true)
  // ADR-0015: target dispatch. `oka run <target>` (and unknown-verb
  // dispatch) delegate here: the target is resolved against [Oka.targets],
  // its compiled steps validated, then run. `--oka-list-targets` prints the
  // declared targets as JSON so the CLI can name them in errors without
  // guessing.
  ..addOption('oka-run-target', hide: true)
  ..addFlag('oka-list-targets', negatable: false, hide: true)
  // ADR-0015 (C2): describe each declared target's compiled step chain —
  // the validated-plan surface, no execution. Used by `oka explain --targets`.
  ..addFlag('oka-describe-targets', negatable: false, hide: true)
  // ADR-0015: invocation-time target overrides. `--oka-target-arg key=value`
  // (repeatable) is the generic typed mechanism — the target validates the
  // keys itself ([Target.applyInvocationArgs]). `--device`/`-d` is a
  // convenience alias forwarded as the `device` key (e.g. DeviceTarget),
  // keeping `oka launch -d` and `oka run device -d` working.
  ..addMultiOption('oka-target-arg', hide: true)
  ..addOption('device', abbr: 'd', hide: true)
  ..addOption('oka-session-state', hide: true);

/// Runs a declarative [Oka] composition from a project hook entrypoint
/// (ADR-0006: `oka build` delegates to `dart run <entrypoint>` which calls
/// this).
///
/// Performs the boilerplate hooks should not repeat: arg parsing, oka.yaml
/// loading, dart-define merging, build directory layout, pipeline selection by
/// `--platform`, and execution.
///
/// A complete project entrypoint (conventionally `tool/oka_pipeline.dart`):
///
/// ```dart
/// import 'package:oka_android/oka_android.dart';
/// import 'package:oka_core/oka_core.dart';
///
/// Future<void> main(List<String> args) => okaRun(
///       args,
///       oka: const Oka(
///         pipelines: [
///           AndroidPipeline(
///             config: AndroidBuild(packageName: 'dev.example.app'),
///           ),
///         ],
///       ),
///     );
/// ```
///
/// Supported CLI flags (forwarded by `oka build`): `--release`, `--debug`,
/// `--profile`, `--aab`, `--verify-aab`, `--platform`, `--flavor`, `--abi`,
/// `--target`, `--dart-define`, `--dart-define-from-file`, and `--verbose`.
///
/// Hidden dispatch flags (ADR-0015, used by `oka run <target>` and the
/// unknown-verb dispatcher): `--oka-run-target <name>` resolves [name]
/// against `Oka.targets`, validates its compiled steps, and runs them
/// instead of the platform pipeline; `--oka-list-targets` prints the
/// declared targets as a JSON array and exits.
///
/// Exits with a non-zero code and a diagnostic on failure.
Future<void> okaRun(
  final List<String> args, {
  required final Oka oka,
  final String? projectPath,
  final ArgParser? extraArgs,
  final Future<void> Function(String projectPath)? registerCacheProject,
}) async {
  final parser = _okaRunParser;
  final results = parser.parse(args);

  final sessionStateRequest = results['oka-session-state'] as String?;
  if (sessionStateRequest != null) {
    await _runSessionStateProtocol(sessionStateRequest, oka);
    return;
  }

  final verbose = results['verbose'] as bool;
  final platform = results['platform'] as String;

  // ADR-0015: machine mode — report the declared targets and exit. Used by
  // the CLI dispatcher to name available targets in unknown-verb errors.
  if (results['oka-list-targets'] as bool) {
    validateTargets(oka);
    stdout.writeln(
      jsonEncode([
        for (final t in oka.targets)
          {'name': t.name, 'description': t.description},
      ]),
    );
    return;
  }

  // ADR-0015 (C2): machine mode for `oka explain --targets` — report each
  // declared target's compiled step chain (validated, never executed). A
  // target whose compile throws is reported as a per-target `error` entry
  // instead of aborting the listing.
  if (results['oka-describe-targets'] as bool) {
    validateTargets(oka);
    final root = projectPath ?? Directory.current.path;
    final ctx = BuildContext(
      projectPath: root,
      buildDir: '',
      mode: BuildMode.debug,
      config: await loadOkaYaml(root),
    );
    stdout.writeln(
      jsonEncode([for (final t in oka.targets) _describeTargetSafely(t, ctx)]),
    );
    return;
  }

  final root = projectPath ?? Directory.current.path;
  final mode = results['release'] as bool
      ? BuildMode.release
      : results['profile'] as bool
      ? BuildMode.profile
      : BuildMode.debug;
  final buildAab = results['aab'] as bool;
  final buildDirMode = buildAab ? '${mode.name}-aab' : mode.name;

  final config = await loadOkaYaml(root);

  // ADR-0015: requested target overrides the platform pipeline. Its config
  // overrides deep-merge over oka.yaml with the same precedence as
  // PlatformPipeline.configOverrides.
  final Target? target;
  final PlatformPipeline? pipeline;
  final requestedTargetName = results['oka-run-target'] as String?;
  if (requestedTargetName != null) {
    final resolved = _resolveTarget(oka, requestedTargetName);
    final invocationArgs = {
      if ((results['device'] as String?)?.trim().isNotEmpty ?? false)
        'device': (results['device'] as String).trim(),
      for (final kv in results['oka-target-arg'] as List<String>)
        ..._parseTargetArg(kv),
    };
    target = invocationArgs.isEmpty
        ? resolved
        : resolved.applyInvocationArgs(invocationArgs);
    pipeline = null;
  } else {
    target = null;
    pipeline = _selectPipeline(oka, platform);
  }
  final mergedMap = mergeConfigMaps(
    config.toJson(),
    target?.configOverrides ?? pipeline!.configOverrides,
  );
  final mergedConfig = OkaConfig.fromJson(mergedMap);

  if (results['print-config'] as bool) {
    stdout.writeln(jsonEncode(mergedMap));
    return;
  }

  final defines = <String, String>{
    ...parseDartDefineFile(results['dart-define-from-file'] as String?),
    for (final d in results['dart-define'] as List<String>)
      ..._parseSingleDefine(d),
  };

  final buildDir = '$root/.oka_cache/build/$buildDirMode';
  await Directory(buildDir).create(recursive: true);

  final ctx = BuildContext(
    projectPath: root,
    buildDir: buildDir,
    mode: mode,
    config: mergedConfig,
    cacheDir: '$root/.oka_cache',
    tempDir: '$buildDir/temp',
    verbose: verbose,
    flavor: results['flavor'] as String,
    targetAbi: results['abi'] as String,
    buildAab: buildAab,
    verifyAab: results['verify-aab'] as bool,
    dartDefines: defines,
    targetOverride: (results['target'] as String?) ?? '',
  );

  final StepResult result;
  if (target != null) {
    // ADR-0015: target pipelines go through the same composition-time
    // artifact validation as platform builds — before any tool runs.
    final targetPipeline = Pipeline(target.compile(ctx), verbose: verbose);
    final validationError = targetPipeline.validate();
    if (validationError != null) {
      stderr.writeln(
        '❌ target "${target.name}" pipeline is invalid: $validationError',
      );
      exit(1);
    }
    // The state handle survives the run: publish targets put their
    // ADR-0014 dry-run plan into it (PublishPlanStep.plan), read below.
    final targetState = PipelineState();
    await registerCacheProjectBestEffort(root, register: registerCacheProject);
    final teardownSteps = target.compileTeardown(ctx);
    final execution = TargetExecutionScope(
      teardownSteps: teardownSteps,
      ctx: ctx,
      state: targetState,
      write: verbose ? stdout.writeln : null,
    );
    result = await execution.run(
      () => targetPipeline.run(
        ctx,
        initialState: targetState,
        shouldCancel: () => execution.cancellationRequested,
      ),
    );
    final plan = targetState[PublishPlanStep.plan.id];
    if (result.ok && plan is PublishPlan) {
      stdout.writeln('📋 Publish plan for "${target.name}":');
      for (final line in plan.describeLines()) {
        stdout.writeln('  $line');
      }
    }
    // ADR-0018 (L1): declarative teardown — same contract as the build
    // steps, run best-effort after the forward pipeline (success OR
    // failure), never masking its result. Owned vs borrowed enforcement
    // and identity gates live in the steps/registry, not here.
    if (teardownSteps.isNotEmpty) {
      final teardown = await execution.teardown();
      if (!teardown.ok) {
        stderr.writeln(
          '⚠️ target "${target.name}" teardown finished with '
          '${teardown.failures.length} failure(s) (never masks the run '
          'result — ADR-0018 §2).',
        );
      }
    }
  } else {
    await registerCacheProjectBestEffort(root, register: registerCacheProject);
    result = await pipeline!.run(ctx);
  }
  if (!result.ok) {
    stderr.writeln('❌ oka run failed: ${result.error}');
    exit(1);
  }
  final apkPath = result.data['apk_path'];
  if (apkPath is String && apkPath.isNotEmpty) {
    stdout.writeln('✅ Build complete: $apkPath');
  }
}

/// Remembers executed projects for global cache management (ADR-0020).
/// Registration is advisory: failures never prevent a build and diagnostics
/// go to stderr so machine-readable stdout stays intact. The callback permits
/// embedders to use their own registry without changing the build contract.
Future<void> registerCacheProjectBestEffort(
  String projectPath, {
  Future<void> Function(String projectPath)? register,
  void Function(String message)? warning,
}) async {
  try {
    await (register ?? CacheProjectRegistry().register)(projectPath);
  } on Object catch (error) {
    final message =
        'Warning: could not register project for global cache management: $error';
    if (warning == null) {
      stderr.writeln(message);
    } else {
      warning(message);
    }
  }
}

/// Describes one target for `oka explain --targets` (ADR-0015), reporting a
/// compile failure as a per-target `error` entry instead of aborting the
/// listing. Never executes anything — [describeTarget] is pure.
Map<String, dynamic> _describeTargetSafely(
  final Target t,
  final BuildContext ctx,
) {
  try {
    return describeTarget(t, ctx).toJson();
  } catch (e) {
    return {
      'name': t.name,
      'description': t.description,
      'error': e.toString(),
    };
  }
}

/// Deep-merges [override] over [base] (one nested level for the
/// `android:`/`flutter:`/`pipeline:` sections). Keys present only in [base]
/// are preserved; keys in [override] win. Pure — used for the ADR-0010
/// typed-Dart-config-over-yaml precedence.
Map<String, dynamic> mergeConfigMaps(
  final Map<String, dynamic> base,
  final Map<String, dynamic> override,
) {
  if (override.isEmpty) return base;
  final out = Map<String, dynamic>.of(base);
  for (final entry in override.entries) {
    final existing = out[entry.key];
    if (existing is Map && entry.value is Map) {
      out[entry.key] = mergeConfigMaps(
        _stringKeyed(existing),
        _stringKeyed(entry.value as Map),
      );
    } else {
      out[entry.key] = entry.value;
    }
  }
  return out;
}

Map<String, dynamic> _stringKeyed(final Map<dynamic, dynamic> m) =>
    m.map((final k, final v) => MapEntry(k.toString(), v));

/// Resolves the project's Dart pipeline entrypoint (ADR-0006/0010):
///
/// 1. `oka.yaml` `pipeline.dart_entrypoint` (explicit),
/// 2. convention: `tool/oka_pipeline.dart`,
/// 3. convention: `bin/oka_pipeline.dart`.
///
/// Returns a project-relative path, or null when the project has no hook
/// (full-YAML project or fresh project). Full-Dart projects (ADR-0010) have
/// no oka.yaml at all — discovery makes them work without any YAML key.
Future<String?> findPipelineEntrypoint(final String projectPath) async {
  final config = await loadOkaYaml(projectPath);
  final pipelineSection = config.toJson()['pipeline'];
  final explicit = pipelineSection is Map
      ? pipelineSection['dart_entrypoint']?.toString()
      : null;
  if (explicit != null && explicit.isNotEmpty) return explicit;
  for (final candidate in const [
    'tool/oka_pipeline.dart',
    'bin/oka_pipeline.dart',
  ]) {
    if (await File('$projectPath/$candidate').exists()) return candidate;
  }
  return null;
}

PlatformPipeline _selectPipeline(final Oka oka, final String platform) {
  for (final p in oka.pipelines) {
    if (p.platform == platform) return p;
  }
  throw ArgumentError(
    'No pipeline for platform "$platform". Declared: '
    '${oka.pipelines.map((final p) => p.platform).join(', ')}',
  );
}

/// Resolves `name` against `Oka.targets` (ADR-0015).
///
/// Throws [TargetResolutionException] when `name` matches no declared
/// target — the message lists the available targets, or explains that the
/// composition root declares none.
Target findTarget(final Oka oka, final String name) {
  for (final t in oka.targets) {
    if (t.name == name) return t;
  }
  if (oka.targets.isEmpty) {
    throw TargetResolutionException(
      'target "$name" not found: the composition root declares no targets.\n'
      'Declare targets in the Oka composition root '
      '(tool/oka_pipeline.dart): Oka(targets: [...]) — see ADR-0015.',
    );
  }
  throw TargetResolutionException(
    'target "$name" not found. Available targets: '
    '${oka.targets.map((final t) => t.name).join(', ')}.',
  );
}

/// Validates every declared target name: lowercase identifier, unique, and
/// never shadowing a reserved core verb (ADR-0015). Throws
/// [TargetResolutionException] naming the first violation.
void validateTargets(final Oka oka) {
  final seen = <String>{};
  for (final t in oka.targets) {
    final error = validateTargetName(t.name);
    if (error != null) throw TargetResolutionException(error);
    if (!seen.add(t.name)) {
      throw TargetResolutionException(
        'duplicate target name "${t.name}" — target names must be unique.',
      );
    }
  }
}

/// Resolves and validates a requested target, exiting with a clean message
/// on failure (used by `oka run <target>` dispatch).
Target _resolveTarget(final Oka oka, final String name) {
  try {
    validateTargets(oka);
    return findTarget(oka, name);
  } on TargetResolutionException catch (e) {
    stderr.writeln('❌ $e');
    exit(1);
  }
}

/// Loads and parses `oka.yaml` from [projectPath]. Missing file → [OkaConfig.empty].
Future<OkaConfig> loadOkaYaml(final String projectPath) async {
  final file = File('$projectPath/oka.yaml');
  if (await file.exists()) {
    return OkaConfig.fromJson(_yamlToJson(await _loadYamlAny(file)));
  }
  // Convenience fallback: a top-level `oka:` section inside pubspec.yaml —
  // one manifest for app + build config. oka.yaml wins when both exist.
  final pubspec = File('$projectPath/pubspec.yaml');
  if (await pubspec.exists()) {
    final doc = await _loadYamlAny(pubspec);
    if (doc is Map && doc['oka'] != null) {
      return OkaConfig.fromJson(_yamlToJson(doc['oka']));
    }
  }
  return OkaConfig.empty;
}

Future<dynamic> _loadYamlAny(final File file) async =>
    loadYaml(await file.readAsString());

dynamic _yamlToJson(final Object? value) {
  if (value is YamlMap) {
    return value.map(
      (final k, final v) => MapEntry(k.toString(), _yamlToJson(v)),
    );
  } else if (value is YamlList) {
    return value.map(_yamlToJson).toList();
  }
  return value;
}

/// Expands `--dart-define-from-file` (JSON object of string values).
Map<String, String> parseDartDefineFile(final String? path) {
  if (path == null || path.isEmpty) return const {};
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('dart-define-from-file not found', path);
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) {
    throw FormatException('dart-define-from-file must be a JSON object', path);
  }
  return decoded.map(
    (final k, final v) => MapEntry(k.toString(), v.toString()),
  );
}

/// Parses a single `key=value` define; a bare key maps to `'true'`
/// (matching the Flutter tool convention).
/// Parses `key=value` from a `--oka-target-arg` occurrence (ADR-0015).
/// Valueless keys map to an empty string so targets can distinguish
/// presence; `=` inside the value is kept.
Map<String, String> _parseTargetArg(final String kv) {
  final i = kv.indexOf('=');
  if (i <= 0) {
    throw ArgumentError('invalid --oka-target-arg "$kv" — expected key=value.');
  }
  return {kv.substring(0, i): kv.substring(i + 1)};
}

Map<String, String> _parseSingleDefine(final String define) {
  final i = define.indexOf('=');
  if (i < 0) return {define: 'true'};
  return {define.substring(0, i): define.substring(i + 1)};
}

const _sessionStateProtocolVersion = 1;
const _sessionStateProtocolSchema = 'oka.session-state.protocol.v1';
const _sessionStateProtocolFramePrefix = '\x1eOKA_SESSION_STATE_V1:';

Future<void> _runSessionStateProtocol(
  final String encodedRequest,
  final Oka oka,
) async {
  Map<String, Object?> response() => {
    'schema_version': _sessionStateProtocolSchema,
    'protocol_version': _sessionStateProtocolVersion,
  };

  try {
    final decoded = jsonDecode(encodedRequest);
    if (decoded is! Map) {
      throw const FormatException('Request must be a JSON object.');
    }
    final request = decoded.cast<String, Object?>();
    const knownFields = {'protocol_version', 'operation', 'lease_id', 'apply'};
    final unknownFields = request.keys.where(
      (final key) => !knownFields.contains(key),
    );
    if (unknownFields.isNotEmpty) {
      throw FormatException(
        'Request has unknown field(s): ${unknownFields.join(', ')}.',
      );
    }
    if (request['protocol_version'] is! int ||
        request['protocol_version'] != _sessionStateProtocolVersion) {
      throw FormatException(
        'Unsupported session-state protocol version '
        '"${request['protocol_version']}".',
      );
    }
    final operation = request['operation'];
    if (operation is! String ||
        !const {
          'inspect',
          'resume',
          'reconcile',
          'close',
          'forget',
        }.contains(operation)) {
      throw const FormatException('Unknown session-state operation.');
    }
    final apply = request['apply'] == true;
    if (request['apply'] != null && request['apply'] is! bool) {
      throw const FormatException('"apply" must be a boolean.');
    }
    final leaseId = request['lease_id'] as String?;
    if (operation != 'reconcile' && (leaseId is! String || leaseId.isEmpty)) {
      throw const FormatException('This operation requires a lease_id.');
    }
    if (apply &&
        operation != 'reconcile' &&
        operation != 'close' &&
        operation != 'forget') {
      throw FormatException('$operation does not accept apply.');
    }
    if (operation == 'reconcile' && request['lease_id'] != null) {
      throw const FormatException('reconcile does not accept a lease_id.');
    }

    final registry = SessionStateRegistry.forCurrentUser();
    final workflows = oka.effectiveSessionStateWorkflows;
    final Object result;
    if (operation == 'resume') {
      final lease = await registry.read(leaseId!);
      if (lease == null) {
        throw FormatException(
          'No session-state lease found with id "$leaseId".',
        );
      }
      final matching = workflows.where(
        (final workflow) =>
            workflow.id == lease.workflowId &&
            workflow.version == lease.workflowVersion,
      );
      if (matching.length != 1) {
        throw FormatException(
          'No unique composed workflow matches '
          '${lease.workflowId}@${lease.workflowVersion}; resume is unavailable.',
        );
      }
      final resumed = await SessionStateManager(
        registry: registry,
      ).resume(matching.single, leaseId);
      result = {'lease': resumed.toJson(), 'status': 'ready'};
    } else {
      final reconciler = SessionStateReconciler(
        registry: registry,
        workflows: workflows,
      );
      final report = switch (operation) {
        'inspect' => await reconciler.inspectLease(leaseId: leaseId!),
        'close' => await reconciler.close(leaseId: leaseId!, apply: apply),
        'forget' => await reconciler.forget(leaseId: leaseId!, apply: apply),
        _ => await reconciler.reconcile(apply: apply),
      };
      result = report.toJson();
    }
    stdout.writeln(
      '$_sessionStateProtocolFramePrefix'
      '${jsonEncode({...response(), 'status': 'ok', 'result': result})}',
    );
  } on Object catch (error) {
    stderr.writeln('Oka session-state protocol: $error');
    stdout.writeln(
      '$_sessionStateProtocolFramePrefix'
      '${jsonEncode({...response(), 'status': 'error', 'error': error.toString()})}',
    );
    exitCode = 1;
  }
}
