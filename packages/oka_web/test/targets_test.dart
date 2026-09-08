// ADR-0016 W0 — target contract tests: names validate, chains compile and
// pass composition-time artifact validation, the delegation is named, and
// config overrides are pure.
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('oka_web_targets_'));

  tearDown(() => temp.deleteSync(recursive: true));

  BuildContext ctx() => BuildContext(
        projectPath: temp.path,
        buildDir: p.join(temp.path, '.oka', 'build'),
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );

  group('WebShellTarget', () {
    test('name passes ADR-0015 target-name validation', () {
      expect(validateTargetName(const WebShellTarget(spec: WebShellSpec(title: 'X')).name), isNull);
      expect(const WebShellTarget(spec: WebShellSpec(title: 'X')).name, 'web-shell');
    });

    test('compile produces validate → emit and passes Pipeline.validate',
        () {
      const target = WebShellTarget(
        spec: WebShellSpec(title: 'Example'),
      );
      final steps = target.compile(ctx());
      expect(steps.map((final s) => s.name).toList(),
          ['validate-web-shell', 'emit-web-shell']);
      expect(Pipeline(steps).validate(), isNull);
    });

    test('describeTarget: valid chain, no tool invocation', () {
      final description = describeTarget(
        const WebShellTarget(spec: WebShellSpec(title: 'Example')),
        ctx(),
      );
      expect(description.isValid, isTrue);
      expect(description.name, 'web-shell');
      expect(
        description.steps.map((final s) => s.name).toList(),
        ['validate-web-shell', 'emit-web-shell'],
      );
      // The emit step consumes the composed shell artifact.
      expect(description.steps[1].requires, ['web-shell']);
      expect(
        description.steps[1].provides,
        containsAll(['web-shell-files', 'web-dir']),
      );
    });

    test('configOverrides is pure (same value every call) and web-scoped',
        () {
      const target = WebShellTarget(
        spec: WebShellSpec(title: 'Example', baseHref: '/app/'),
      );
      expect(target.configOverrides, target.configOverrides);
      expect(target.configOverrides, {
        'web': {'base_href': '/app/', 'emitter': 'generate', 'dir': 'web'},
      });
    });

    test('inject emitter selection changes the description and chain', () {
      const target = WebShellTarget(
        spec: WebShellSpec(title: 'Legacy'),
        emitter: InjectShellEmitter(),
      );
      expect(
        target.description,
        contains('inject emitter: index.html'),
      );
      expect(Pipeline(target.compile(ctx())).validate(), isNull);
    });

    test('contribution overrides flow into the composed shell', () {
      const target = WebShellTarget(
        spec: WebShellSpec(title: 'Example'),
        contributions: [
          SimpleWebShellContribution(
            baseHref: '/store/',
            head: [
              WebLinkEntry(
                rel: 'preconnect',
                href: 'https://cdn.example.com',
                phase: WebHeadPhase.preconnect,
              ),
            ],
          ),
        ],
      );
      expect(target.compose().baseHref, '/store/');
      expect(
        target.configOverrides,
        {
          'web': {'base_href': '/store/', 'emitter': 'generate', 'dir': 'web'},
        },
      );
    });
  });

  group('WebBuildTarget', () {
    test('name passes ADR-0015 target-name validation', () {
      expect(validateTargetName(const WebBuildTarget().name), isNull);
      expect(const WebBuildTarget().name, 'web-build');
    });

    test('description names the delegation explicitly', () {
      expect(
        const WebBuildTarget().description,
        contains('delegates to flutter build web (not an oka-owned pipeline)'),
      );
    });

    test('compile produces the delegation step; chain validates', () {
      const target = WebBuildTarget(baseHref: '/games/');
      final steps = target.compile(ctx());
      expect(steps.map((final s) => s.name).toList(),
          ['flutter-web-build']);
      expect(Pipeline(steps).validate(), isNull);
      final description = describeTarget(target, ctx());
      expect(description.isValid, isTrue);
    });

    test('base href flows from config; contribution override wins', () {
      expect(
        const WebBuildTarget(baseHref: '/cfg/').effectiveBaseHref,
        '/cfg/',
      );
      expect(
        const WebBuildTarget(
          baseHref: '/cfg/',
          contributions: [
            SimpleWebShellContribution(baseHref: '/store/'),
          ],
        ).effectiveBaseHref,
        '/store/',
      );
    });

    test('configOverrides is pure and declares the delegation', () {
      const target = WebBuildTarget(baseHref: '/x/');
      expect(target.configOverrides, target.configOverrides);
      expect(target.configOverrides, {
        'web': {'base_href': '/x/', 'delegation': 'flutter build web'},
      });
    });
  });

  group('explainDetails (ADR-0016 W1, pure)', () {
    test('WebShellTarget: the composed-shell render, no execution', () {
      final description = describeTarget(
        const WebShellTarget(
          spec: WebShellSpec(title: 'Example'),
          contributions: [
            SimpleWebShellContribution(
              head: [
                WebScriptEntry(
                  src: 'https://store.example/sdk.js',
                  phase: WebHeadPhase.storeSdk,
                  requiredSdkGlobal: 'StoreSdk',
                ),
              ],
            ),
          ],
        ),
        ctx(),
      );
      expect(description.isValid, isTrue);
      final details = description.details.join('\n');
      expect(details, contains('shell: "Example"'));
      expect(details, contains('requiredSdkGlobal=StoreSdk'));
      expect(details, contains('post-emit drift gate'));
    });

    test('GhPagesDeployTarget: dry-run default named as the deploy posture',
        () {
      final details = const GhPagesDeployTarget()
          .explainDetails(ctx())
          .join('\n');
      expect(details, contains('directory-artifact convention'));
      expect(details, contains('dry run: yes'));
      expect(details, contains('flip dryRun: false'));
    });

    test('ItchDeployTarget: channel address and dry-run posture', () {
      final details = const ItchDeployTarget(user: 'u', game: 'g')
          .explainDetails(ctx())
          .join('\n');
      expect(details, contains('u/g:web'));
      expect(details, contains('dry run: yes'));
    });
  });
}
