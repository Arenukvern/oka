import 'dart:io';

import 'package:oka_core/oka_core.dart';

// ignore: implementation_imports
import 'auto_resolve.dart';
import 'build/sdk_locator.dart';

import 'android_artifacts.dart';
import 'android_state.dart';
import 'signing_config.dart';

/// Result of one lint rule.
class LintFinding {
  final String rule;
  final Severity severity;
  final String message;

  const LintFinding(this.rule, this.severity, this.message);

  @override
  String toString() => '[$severity] $rule: $message';
}

enum Severity { info, warning, error }

/// Individual lint rules — composable, each a pure function over the
/// packaged artifact. Add rules by appending to [defaultRules] or by
/// supplying a custom list.
typedef LintRule = Future<List<LintFinding>> Function(
  PostBuildLintStep step,
  BuildContext ctx,
  PipelineState state,
);

/// Resolved signing info for lint rules: whether a real keystore backs the
/// build and the keystore path when known.
Future<SigningConfig?> resolvedSigning(BuildContext ctx) =>
    SigningConfig.autoResolve(ctx);

/// Post-build lint (ADR-0007): runs after packaging, checks the artifact is
/// actually releasable. Errors fail the build.
class PostBuildLintStep extends BuildStep {
  /// File size budget in MB (null = no check).
  final int? maxSizeMb;

  /// When true, a debug-signed release artifact is an error, not a warning.
  final bool strictSigning;

  /// When true, print badging info (version, label) as info findings.
  final bool showBadging;

  /// Extra rules composed by hooks/Dart pipelines.
  final List<LintRule> extraRules;

  @override
  String get name => 'post-build-lint';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  PostBuildLintStep({
    this.maxSizeMb,
    this.strictSigning = true,
    this.showBadging = false,
    this.extraRules = const [],
  });

  List<LintRule> get defaultRules => [
    _manifestVersionRule,
    _debugSigningRule,
    _bundleConfigRule,
  ];

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    final rules = [...defaultRules, ...extraRules];
    final findings = <LintFinding>[];
    for (final rule in rules) {
      findings.addAll(await rule(this, ctx, state));
    }
    if (maxSizeMb != null) {
      findings.addAll(await _sizeBudgetRule(this, ctx, state, maxSizeMb!));
    }

    final errors = findings.where((f) => f.severity == Severity.error);
    for (final f in findings) {
      switch (f.severity) {
        case Severity.error:
          print('❌ lint [${f.rule}]: ${f.message}');
        case Severity.warning:
          print('⚠️  lint [${f.rule}]: ${f.message}');
        case Severity.info:
          if (showBadging) print('ℹ️  lint [${f.rule}]: ${f.message}');
      }
    }
    if (errors.isNotEmpty) {
      return StepResult.failure(
        'post-build lint failed:\n'
        '${errors.map((e) => '  - [${e.rule}] ${e.message}').join('\n')}',
      );
    }
    return StepResult.success();
  }
}

/// Manifest version attributes actually present in the packaged APK/AAB.
Future<List<LintFinding>> _manifestVersionRule(
  PostBuildLintStep step,
  BuildContext ctx,
  PipelineState state,
) async {
  final findings = <LintFinding>[];
  final apk = state.apkPath;
  if (apk == null || !File(apk).existsSync()) {
    return [const LintFinding('manifest-version', Severity.error, 'artifact missing')];
  }
  final version = resolveAndroidVersion(
    ctx.projectPath,
    configVersionCode: ctx.config.android.versionCode,
    configVersionName: ctx.config.android.versionName,
  );
  if (version.versionCode == 0 || version.versionName.isEmpty) {
    findings.add(
      const LintFinding(
        'manifest-version',
        Severity.error,
        'no version code/name resolved (oka.yaml android.version_code or '
        'pubspec version required)',
      ),
    );
  }
  return findings;
}

/// Debug-signed release artifact gate.
Future<List<LintFinding>> _debugSigningRule(
  PostBuildLintStep step,
  BuildContext ctx,
  PipelineState state,
) async {
  if (!ctx.mode.isRelease) return const [];
  final configured = await resolvedSigning(ctx);
  if (configured != null && configured.isConfigured) {
    return [
      LintFinding(
        'signing',
        Severity.info,
        'release keystore: ${configured.keyAlias}',
      ),
    ];
  }
  return [
    LintFinding(
      'signing',
      step.strictSigning ? Severity.error : Severity.warning,
      'release artifact would be DEBUG-signed — configure '
      'android/key.properties or oka.yaml android.signing '
      '(escape: --allow-debug-signing)',
    ),
  ];
}

/// AAB BundleConfig must carry a bundletool version.
Future<List<LintFinding>> _bundleConfigRule(
  PostBuildLintStep step,
  BuildContext ctx,
  PipelineState state,
) async {
  if (!ctx.buildAab) return const [];
  final pb = File('${ctx.buildDir}/aab/BundleConfig.pb');
  if (!pb.existsSync()) {
    return [
      const LintFinding(
        'bundle-config',
        Severity.error,
        'BundleConfig.pb missing from bundle root',
      ),
    ];
  }
  final bytes = pb.readAsBytesSync();
  // Structure check: BundleConfig { bundletool { version: "..." } } encodes
  // as 0x0A <len> 0x12 <len> <ascii digits/dots>.
  if (bytes.length < 10 || bytes[0] != 0x0A || bytes[2] != 0x12) {
    return [
      const LintFinding(
        'bundle-config',
        Severity.error,
        'BundleConfig.pb lacks a bundletool version — bundletool ≥1.x '
        'rejects such bundles',
      ),
    ];
  }
  return const [];
}

/// Artifact size budget.
Future<List<LintFinding>> _sizeBudgetRule(
  PostBuildLintStep step,
  BuildContext ctx,
  PipelineState state,
  int maxSizeMb,
) async {
  final apk = state.apkPath;
  if (apk == null || !File(apk).existsSync()) return const [];
  final sizeMb = File(apk).lengthSync() / (1024 * 1024);
  if (sizeMb > maxSizeMb) {
    return [
      LintFinding(
        'size-budget',
        Severity.error,
        'artifact is ${sizeMb.toStringAsFixed(1)} MB — budget is $maxSizeMb MB',
      ),
    ];
  }
  return [
    LintFinding(
      'size-budget',
      Severity.info,
      '${sizeMb.toStringAsFixed(1)} MB (budget $maxSizeMb MB)',
    ),
  ];
}
