import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

Never _fail(String message) {
  stderr.writeln('check_toolchain_versions: $message');
  exit(1);
}

void main() {
  final root = Directory(
    Platform.environment['OKA_ROOT'] ??
        File.fromUri(Platform.script).parent.parent.parent.path,
  ).absolute;

  final versionsFile = File(p.join(root.path, 'tool/ci/toolchain_versions.yaml'));
  final versions =
      loadYaml(versionsFile.readAsStringSync()) as Map<dynamic, dynamic>;
  final constraint = versions['dart_sdk_constraint'] as String;
  final flutterMin = versions['flutter_min'] as String;

  final ci = File(p.join(root.path, '.github/workflows/ci.yml')).readAsStringSync();
  if (!ci.contains('sdk: 3.14.1')) {
    _fail('ci.yml must pin Dart 3.14.1 (tool/ci/toolchain_versions.yaml)');
  }
  if (!ci.contains('flutter-version: "3.50.0"')) {
    _fail('ci.yml must pin Flutter 3.50.0');
  }

  var pubspecCount = 0;
  for (final entity in root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('pubspec.yaml'))) {
    final content = entity.readAsStringSync();
    if (!content.contains('sdk: ^')) continue;
    pubspecCount++;
    if (content.contains('sdk: ^3.13.0')) {
      _fail('stale sdk floor ^3.13.0 in ${entity.path}');
    }
    if (!content.contains('sdk: $constraint')) {
      _fail('${entity.path} must declare sdk: $constraint');
    }
  }

  final rootPub = File(p.join(root.path, 'pubspec.yaml')).readAsStringSync();
  if (!rootPub.contains('sdk: $constraint')) {
    _fail('root pubspec.yaml must declare sdk: $constraint');
  }

  for (final docPath in [
    'README.md',
    'docs/FAQ.md',
    'docs/guides/build_and_config.mdx',
    'docs/contributing/contribution_guide.mdx',
  ]) {
    final text = File(p.join(root.path, docPath)).readAsStringSync();
    if (!text.contains('3.14')) {
      _fail('$docPath must mention Dart 3.14+');
    }
    if (!text.contains('3.50') && docPath != 'README.md') {
      _fail('$docPath must mention Flutter 3.50');
    }
  }
  final readme = File(p.join(root.path, 'README.md')).readAsStringSync();
  if (!readme.contains('3.50')) {
    _fail('README.md must mention Flutter 3.50 badge or text');
  }

  stdout.writeln(
    'check_toolchain_versions: ok ($pubspecCount package pubspecs, '
    'Flutter $flutterMin)',
  );
}
