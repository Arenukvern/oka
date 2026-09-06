
import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  group('ADR-0006 composition-time artifact validation', () {
    test('missing requirement fails before any step runs', () async {
      final executed = <String>[];
      final ran = _RecordingStep('ran', sink: executed);
      final needsMissing = _RecordingStep(
        'needs-missing',
        sink: executed,
        requires: {const Artifact<Object>('never-produced')},
      );
      final pipeline = Pipeline([ran, needsMissing]);
      final result = await pipeline.run(BuildContext.empty);
      expect(result.ok, isFalse);
      expect(result.error, contains('never-produced'));
      expect(result.error, contains('needs-missing'));
      // Validation must run BEFORE any step executes.
      expect(executed, isEmpty);
    });

    test('satisfied chain runs all steps in order', () async {
      final executed = <String>[];
      final producer = _RecordingStep(
        'producer',
        sink: executed,
        provides: {const Artifact<Object>('thing')},
      );
      final consumer = _RecordingStep(
        'consumer',
        sink: executed,
        requires: {const Artifact<Object>('thing')},
      );
      final result = await Pipeline([producer, consumer]).run(
        BuildContext.empty,
      );
      expect(result.ok, isTrue);
      expect(executed, ['producer', 'consumer']);
    });

    test('out-of-order requirement fails with actionable message', () async {
      final producer = _RecordingStep(
        'producer',
        provides: {const Artifact<Object>('thing')},
      );
      final consumer = _RecordingStep(
        'consumer',
        requires: {const Artifact<Object>('thing')},
      );
      final result = await Pipeline([consumer, producer]).run(
        BuildContext.empty,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('Declare a provider before "consumer"'));
    });

    test('duplicate providers with same artifact id are rejected', () async {
      final a = _RecordingStep('a', provides: {const Artifact<Object>('x')});
      final b = _RecordingStep('b', provides: {const Artifact<Object>('x')});
      final result = await Pipeline([a, b]).run(BuildContext.empty);
      expect(result.ok, isFalse);
      expect(result.error, contains('must be unique'));
    });

    test('default APK pipeline validates cleanly', () {
      // The default step list must have a coherent artifact chain.
      final pipeline = Pipeline(AndroidPipeline.defaultSteps);
      expect(pipeline.validate(), isNull);
    });
  });

  group('typed BuildContext (ADR-0006)', () {
    test('fromJson/copyWith/toJson round-trip', () {
      final ctx = BuildContext.fromJson({
        'project_path': '/tmp/proj',
        'build_dir': '/tmp/proj/.oka_cache/build/debug',
        'mode': 'release',
        'config': {
          'name': 'app',
          'android': {'package_name': 'dev.example.app', 'min_sdk': 25},
        },
        'target_override': 'lib/main_prod.dart',
        'dart_defines': {'STORE': 'googlePlay'},
      });
      expect(ctx.mode, BuildMode.release);
      expect(ctx.targetOverride, 'lib/main_prod.dart');
      expect(ctx.entrypoint, 'lib/main_prod.dart');
      expect(ctx.dartDefines['STORE'], 'googlePlay');

      final overridden = ctx.copyWith(
        dartDefines: const {'STORE': 'rustore'},
        targetOverride: 'lib/main.dart',
      );
      expect(overridden.dartDefines['STORE'], 'rustore');
      expect(overridden.targetOverride, 'lib/main.dart');
      // Original immutable.
      expect(ctx.dartDefines['STORE'], 'googlePlay');
    });

    test('entrypoint falls back to oka.yaml then lib/main.dart', () {
      const empty = BuildContext.empty;
      expect(empty.entrypoint, 'lib/main.dart');
    });
  });
}

/// Step that records execution order and declares artifacts.
class _RecordingStep extends BuildStep {
  final String _name;
  final List<String>? _sink;
  @override
  final Set<Artifact<Object>> requires;
  @override
  final Set<Artifact<Object>> provides;

  _RecordingStep(
    String name, {
    List<String>? sink,
    this.requires = const {},
    this.provides = const {},
  }) : _name = name,
       _sink = sink;

  @override
  String get name => _name;

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    _sink?.add(_name);
    return StepResult.success();
  }
}
