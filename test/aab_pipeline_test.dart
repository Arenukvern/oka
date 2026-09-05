import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Source-contract tests for the AAB pipeline wiring (ADR-0004).
void main() {
  test('default pipeline exposes AAB steps', () async {
    final text = await File(
      p.join('packages', 'oka_android', 'lib', 'src', 'pipeline', 'default_pipeline.dart'),
    ).readAsString();
    expect(text, contains('defaultAabPipeline'));
    expect(text, contains('CompileProtoAndDexStep'));
    expect(text, contains('PackageAndSignAabStep'));
    expect(text, contains('ValidateAabLayoutStep'));
  });

  test('toolchain uses proto-format link for AAB', () async {
    final text = await File(
      p.join('packages', 'oka_android', 'lib', 'src', 'pipeline', 'toolchain.dart'),
    ).readAsString();
    expect(text, contains('buildAapt2LinkProtoFormatArgs'));
    expect(text, contains('resources_proto.ap_'));
    // Bundles sign with jarsigner (v1), never apksigner.
    expect(text, contains('signAab'));
  });

  test('builder dispatches on ctx.buildAab (no fallback warning)', () async {
    final builder = await File(
      p.join('packages', 'oka_android', 'lib', 'src', 'build', 'flutter_apk_builder.dart'),
    ).readAsString();
    expect(builder, contains('ctx.buildAab'));
    expect(builder, contains('defaultAabPipeline'));

    final cli = await File(
      p.join('lib', 'src', 'cli', 'build_command.dart'),
    ).readAsString();
    // The old "limited AAB" warning must be gone.
    expect(cli, isNot(contains('not the primary path yet')));
  });
}
