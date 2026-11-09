import 'package:test/test.dart';

import 'support/repo_root.dart';

/// Source-contract tests for the AAB pipeline wiring (ADR-0004).
void main() {
  setUpAll(guardOkaWorkspaceCwd);

  test('default pipeline exposes AAB steps', () async {
    guardOkaWorkspaceCwd();
    final text = await repoFile([
      'packages',
      'oka_android',
      'lib',
      'src',
      'pipeline',
      'default_pipeline.dart',
    ]).readAsString();
    expect(text, contains('defaultAabPipeline'));
    expect(text, contains('CompileProtoAndDexStep'));
    expect(text, contains('PackageAndSignAabStep'));
    expect(text, contains('ValidateAabLayoutStep'));
  });

  test('resource compilation uses proto-format link for AAB', () async {
    guardOkaWorkspaceCwd();
    final text = await repoFile([
      'packages',
      'oka_android',
      'lib',
      'src',
      'compilation',
      'resource_compilation.dart',
    ]).readAsString();
    expect(text, contains('buildAapt2LinkProtoFormatArgs'));
    expect(text, contains('resources_proto.ap_'));
    final signing = await repoFile([
      'packages',
      'oka_android',
      'lib',
      'src',
      'signing',
      'android_signing.dart',
    ]).readAsString();
    // Bundles sign with jarsigner (v1), never apksigner.
    expect(signing, contains('signAab'));
  });

  test('builder dispatches on ctx.buildAab (no fallback warning)', () async {
    guardOkaWorkspaceCwd();
    final builder = await repoFile([
      'packages',
      'oka_android',
      'lib',
      'src',
      'build',
      'flutter_apk_builder.dart',
    ]).readAsString();
    expect(builder, contains('ctx.buildAab'));
    expect(builder, contains('defaultAabPipeline'));

    final cli = await repoFile([
      'packages',
      'oka',
      'lib',
      'src',
      'cli',
      'build_command.dart',
    ]).readAsString();
    // The old "limited AAB" warning must be gone.
    expect(cli, isNot(contains('not the primary path yet')));
  });
}
