import 'dart:io';

import 'package:oka_android/src/build/cargo_apk_manifest.dart';
import 'package:oka_core/src/config/build_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  BuildContext sampleCtx({String buildDir = '/tmp/oka_build'}) {
    return BuildContext.fromJson({
      'project_path': '/tmp/project',
      'build_dir': buildDir,
      'mode': 'debug',
      'config': {
        'name': 'example',
        'version': '1.0.0',
        'android': {
          'package_name': 'com.example.example',
          'min_sdk': '21',
          'target_sdk': '34',
          'compile_sdk': '34',
          'version_code': 1,
          'version_name': '1.0.0',
          'abis': ['arm64-v8a'],
        },
        'flutter': {
          'entrypoint': 'lib/main.dart',
        },
        'cargo_apk': {
          'build_targets': ['arm64-v8a'],
          'application': {'label': 'Example'},
          'permissions': ['android.permission.INTERNET'],
        },
      },
      'cache_dir': '/tmp/cache',
      'temp_dir': '/tmp/temp',
      'verbose': false,
      'target_abi': '',
      'build_aab': false,
    });
  }

  test('generateAndroidMetadataToml is well-formed (no duplicate assets)', () {
    final gen = CargoApkManifest();
    final toml = gen.generateAndroidMetadataToml(sampleCtx());
    expect(CargoApkManifest.isWellFormedMetadata(toml), isTrue);
    expect(toml, contains('[package.metadata.android]'));
    expect(toml, contains('com.example.example'));
    // Must not emit free-floating duplicate keys like the old bug
    final assetsCount =
        RegExp(r'^\s*assets\s*=', multiLine: true).allMatches(toml).length;
    expect(assetsCount, lessThanOrEqualTo(1));
  });

  test('writeManifestTo only touches explicit destination', () async {
    final tmp = await Directory.systemTemp.createTemp('oka_cargo_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    // Shared wrapper that must remain untouched
    final shared = File(p.join(tmp.path, 'rust_wrapper', 'Cargo.toml'));
    await shared.parent.create(recursive: true);
    const sharedOriginal = '''
[package]
name = "flutter_wrapper"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
log = "0.4"
''';
    await shared.writeAsString(sharedOriginal);

    final buildDir = p.join(tmp.path, 'build');
    final dest = p.join(buildDir, 'cargo_apk', 'Cargo.toml');
    final ctx = sampleCtx(buildDir: buildDir);

    final gen = CargoApkManifest();
    await gen.writeManifestTo(ctx: ctx, destinationCargoToml: dest);
    // Also exercise generateManifest default (writes under buildDir)
    await gen.generateManifest(ctx);

    expect(await File(dest).exists(), isTrue);
    final written = await File(dest).readAsString();
    expect(written, contains('[package.metadata.android]'));

    // Shared rust_wrapper must be identical
    expect(await shared.readAsString(), sharedOriginal);
  });

  test('stripAndroidMetadataSections removes nested android tables', () {
    const dirty = '''
[package]
name = "x"

[package.metadata.android]
package = "a"

[package.metadata.android.application]
label = "L"

[dependencies]
log = "0.4"
''';
    final cleaned = CargoApkManifest.stripAndroidMetadataSections(dirty);
    expect(cleaned, isNot(contains('package.metadata.android')));
    expect(cleaned, contains('[dependencies]'));
    expect(cleaned, contains('[package]'));
  });

  test('repo rust_wrapper Cargo.toml is valid enough for cargo metadata', () async {
    final root = Directory.current.path;
    // When run from package root
    final cargo = File(p.join(root, 'rust_wrapper', 'Cargo.toml'));
    if (!await cargo.exists()) {
      // Skip if cwd is not package root
      return;
    }
    final text = await cargo.readAsString();
    expect(text, contains('[package]'));
    expect(text, contains('name = "flutter_wrapper"'));
    // No free-floating version_code spam from old generator
    expect(
      RegExp(r'^version_code\s*=', multiLine: true).hasMatch(text),
      isFalse,
    );
    final result = await Process.run(
      'cargo',
      ['metadata', '--no-deps', '--format-version', '1'],
      workingDirectory: p.join(root, 'rust_wrapper'),
    );
    expect(
      result.exitCode,
      0,
      reason: 'stderr: ${result.stderr}\nstdout: ${result.stdout}',
    );
  });
}
