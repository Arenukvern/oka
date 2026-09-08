// ADR-0016 W1 — the drift gate.
//
// The pure comparator (checkShellDrift): no-drift, drift-detected (with an
// actionable message), missing owned paths, marker-region-only rewrite
// (inject idempotency), and marker-missing failures. Plus the post-emit
// wiring in EmitWebShellStep: re-render must equal the written bytes, and
// a non-idempotent emitter fails with the drift named.
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _shell = WebShell(spec: WebShellSpec(title: 'Drift'));

/// A shell with one app-phase head entry, so the inject marker region is
/// non-empty (hand-edit detection needs owned content to differ).
const _injectedShell = WebShell(
  spec: WebShellSpec(title: 'Drift'),
  contributions: [
    SimpleWebShellContribution(head: [WebMetaEntry(name: 'oka-managed')]),
  ],
);

const _legacyHtml = '''
<!DOCTYPE html>
<html>
<head>
  <title>legacy</title>
  <!-- oka:begin:head -->
  <!-- oka:end:head -->
</head>
<body>
  <!-- oka:begin:body -->
  <!-- oka:end:body -->
  <div id="app"></div>
</body>
</html>
''';

/// Reads the current disk contents of an emitter's owned paths under
/// [webDir] (null = missing) — the thin I/O helper around the pure gate.
Map<String, String?> readOwnedPaths(
  final ShellEmitter emitter,
  final String webDir,
) => {
      for (final owned in emitter.ownedPaths)
        owned: () {
          final f = File(p.join(webDir, owned));
          return f.existsSync() ? f.readAsStringSync() : null;
        }(),
    };

void main() {
  group('checkShellDrift (pure)', () {
    test('no drift: generate emitter, owned files == the composition render',
        () {
      final rendered = const GenerateShellEmitter().emit(_shell).files;
      final report = checkShellDrift(
        shell: _shell,
        emitter: const GenerateShellEmitter(),
        currentFiles: rendered,
      );
      expect(report.isClean, isTrue);
      expect(report.describeLines().single, contains('drift gate: clean'));
    });

    test('no drift: inject emitter re-render is a no-op on the injected file '
        '(marker-region-only rewrite)', () {
      final injected = const InjectShellEmitter()
          .emit(_injectedShell, existingIndexHtml: _legacyHtml)
          .files['index.html']!;
      final report = checkShellDrift(
        shell: _injectedShell,
        emitter: const InjectShellEmitter(),
        currentFiles: {'index.html': injected},
      );
      expect(report.isClean, isTrue);
    });

    test('drift detected: hand-edit inside an owned region (generate)',
        () {
      final report = checkShellDrift(
        shell: _shell,
        emitter: const GenerateShellEmitter(),
        currentFiles: {
          'index.html': '<!DOCTYPE html>\n<html><!-- hand-edited --></html>',
          'manifest.json': null, // and the manifest was deleted
        },
      );
      expect(report.isClean, isFalse);
      expect(report.drifts, hasLength(2));
      final indexDrift =
          report.drifts.firstWhere((final d) => d.path == 'index.html');
      expect(indexDrift.message, allOf([
        contains('owned by the "generate" emitter'),
        contains('first difference'),
        contains('oka run web-shell'),
        contains('edit the composition'),
      ]));      final manifestDrift =
          report.drifts.firstWhere((final d) => d.path == 'manifest.json');
      expect(manifestDrift.message, contains('missing on disk'));
    });

    test('drift detected: hand-edit inside the inject marker region', () {
      final injected = const InjectShellEmitter()
          .emit(_injectedShell, existingIndexHtml: _legacyHtml)
          .files['index.html']!;
      // Someone hand-edits INSIDE the oka-managed head region.
      final edited = injected.replaceFirst(
        '<meta name="oka-managed" content="">',
        '<meta name="hand-edited" content="yes">',
      );
      expect(edited, isNot(injected), reason: 'precondition: edit applied');
      final report = checkShellDrift(
        shell: _injectedShell,
        emitter: const InjectShellEmitter(),
        currentFiles: {'index.html': edited},
      );
      expect(report.isClean, isFalse);
      expect(report.drifts.single.path, 'index.html');
      expect(report.drifts.single.message, contains('oka marker regions'));
    });

    test('drift detected: markers removed after injection fails the gate '
        "with the emitter's actionable message", () {
      final stripped = _legacyHtml
          .replaceFirst('  <!-- oka:begin:head -->\n', '')
          .replaceFirst('  <!-- oka:end:head -->\n', '');
      final report = checkShellDrift(
        shell: _shell,
        emitter: const InjectShellEmitter(),
        currentFiles: {'index.html': stripped},
      );
      expect(report.isClean, isFalse);
      expect(
        report.drifts.single.message,
        allOf([contains('cannot re-render'), contains('no head markers')]),
      );
    });

    test('drift detected: emitter declares ownership it does not render',
        () {
      // `extra-owned.txt` is NOT in ownedPaths → no false-positive drift.
      expect(checkShellDrift(
        shell: _shell,
        emitter: const GenerateShellEmitter(),
        currentFiles: {
          ...const GenerateShellEmitter().emit(_shell).files,
          'extra-owned.txt': 'present',
        },
      ).isClean, isTrue);
      // The opposite: an owned path absent from the emitter output.
      final buggy = checkShellDrift(
        shell: _shell,
        emitter: const _BuggyEmitter(),
        currentFiles: const {'ghost.html': 'on disk'},
      );
      expect(buggy.isClean, isFalse);
      expect(
        buggy.drifts.single.message,
        contains('ownedPaths must exactly match the emitted files'),
      );
    });
  });

  group('EmitWebShellStep post-emit drift gate', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('oka_web_drift_'));
    tearDown(() => temp.deleteSync(recursive: true));

    BuildContext ctx() => BuildContext(
          projectPath: temp.path,
          buildDir: p.join(temp.path, '.oka', 'build'),
          mode: BuildMode.debug,
          config: OkaConfig.empty,
        );

    test('success path: written bytes reproduce the re-render (drift clean)',
        () async {
      final pipeline = Pipeline([
        ValidateWebShellStep(shell: _shell, webDir: p.join(temp.path, 'web')),
        EmitWebShellStep(
          emitter: const GenerateShellEmitter(),
          webDir: p.join(temp.path, 'web'),
        ),
      ]);
      final result = await pipeline.run(ctx());
      expect(result.ok, isTrue, reason: result.error ?? '');

      // The on-disk file also passes the standalone gate (the post-emit
      // drift check inside the step is what kept the run green).
      final report = checkShellDrift(
        shell: _shell,
        emitter: const GenerateShellEmitter(),
        currentFiles: readOwnedPaths(
          const GenerateShellEmitter(),
          p.join(temp.path, 'web'),
        ),
      );
      expect(report.isClean, isTrue);
    });

    test('inject success path: post-emit re-read re-renders as a no-op',
        () async {
      final webDir = p.join(temp.path, 'web');
      Directory(webDir).createSync(recursive: true);
      File(p.join(webDir, 'index.html')).writeAsStringSync(_legacyHtml);
      final pipeline = Pipeline([
        ValidateWebShellStep(
          shell: _injectedShell,
          webDir: webDir,
        ),
        EmitWebShellStep(
          emitter: const InjectShellEmitter(),
          webDir: webDir,
        ),
      ]);
      final result = await pipeline.run(ctx());
      expect(result.ok, isTrue, reason: result.error ?? '');
      // Everything outside the markers survived the emit byte-for-byte.
      expect(
        File(p.join(webDir, 'index.html')).readAsStringSync(),
        contains('<div id="app"></div>'),
      );
      // And the injected managed region matches the composition.
      expect(
        File(p.join(webDir, 'index.html')).readAsStringSync(),
        contains('<meta name="oka-managed" content="">'),
      );
    });

    test('a non-idempotent emitter fails with the drift named', () async {
      final pipeline = Pipeline([
        ValidateWebShellStep(shell: _shell, webDir: p.join(temp.path, 'web')),
        EmitWebShellStep(
          emitter: _NonIdempotentEmitter(),
          webDir: p.join(temp.path, 'web'),
        ),
      ]);
      final result = await pipeline.run(ctx());
      expect(result.ok, isFalse);
      expect(
        result.error,
        allOf([
          contains('post-emit drift gate failed'),
          contains('index.html'),
          contains('first difference'),
        ]),
      );
    });
  });
}

/// A test-only emitter that declares ownership of a path it never renders
/// (the drift gate must catch the broken ownedPaths contract).
class _BuggyEmitter extends ShellEmitter {
  const _BuggyEmitter();

  @override
  String get name => 'buggy';

  @override
  Set<String> get ownedPaths => const {'ghost.html'};

  @override
  ShellOutput emit(final WebShell shell, {final String? existingIndexHtml}) =>
      const ShellOutput(files: {});
}

/// A test-only emitter that is NOT a pure function of its inputs — every
/// call renders something new. The post-emit drift gate must fail it.
class _NonIdempotentEmitter extends ShellEmitter {
  var _call = 0;

  @override
  String get name => 'non-idempotent';

  @override
  Set<String> get ownedPaths => const {'index.html'};

  @override
  ShellOutput emit(final WebShell shell, {final String? existingIndexHtml}) {
    _call++;
    return ShellOutput(
      files: {
        'index.html':
            '<!DOCTYPE html>\n<title>Drift</title>\n<!-- call $_call -->\n',
      },
    );
  }
}
