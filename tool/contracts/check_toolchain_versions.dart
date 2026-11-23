import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'contract_tree_scan.dart';

Never _fail(String message) {
  stderr.writeln('check_toolchain_versions: $message');
  exit(1);
}

Map<String, String> _loadToolchainVersions(Directory root) {
  final versionsFile = File(p.join(root.path, 'tool/ci/toolchain_versions.yaml'));
  if (!versionsFile.existsSync()) {
    _fail('missing tool/ci/toolchain_versions.yaml');
  }
  final raw = loadYaml(versionsFile.readAsStringSync()) as Map<dynamic, dynamic>;
  String req(String key) {
    final value = raw[key];
    if (value is! String || value.isEmpty) {
      _fail('tool/ci/toolchain_versions.yaml: missing or empty $key');
    }
    return value;
  }

  return {
    'dart_sdk_min': req('dart_sdk_min'),
    'dart_sdk_constraint': req('dart_sdk_constraint'),
    'dart_ci_pin': req('dart_ci_pin'),
    'flutter_min': req('flutter_min'),
    'flutter_ci_pin': req('flutter_ci_pin'),
  };
}

void _assertCiPinsMatchYaml(Directory root, Map<String, String> versions) {
  final ciPath = p.join(root.path, '.github/workflows/ci.yml');
  if (!File(ciPath).existsSync()) {
    _fail('missing .github/workflows/ci.yml');
  }
  final ci = File(ciPath).readAsStringSync();
  final dartPin = versions['dart_ci_pin']!;
  final flutterPin = versions['flutter_ci_pin']!;
  final dartNeedle = RegExp(r'sdk:\s*' + RegExp.escape(dartPin));
  final flutterNeedle =
      RegExp('flutter-version:\\s*"${RegExp.escape(flutterPin)}"');
  if (!dartNeedle.hasMatch(ci)) {
    _fail(
      'ci.yml must pin Dart $dartPin (tool/ci/toolchain_versions.yaml dart_ci_pin)',
    );
  }
  if (!flutterNeedle.hasMatch(ci)) {
    _fail(
      'ci.yml must pin Flutter $flutterPin '
      '(tool/ci/toolchain_versions.yaml flutter_ci_pin)',
    );
  }
}

final _sdkFloorPattern = RegExp(r'sdk:\s*\^([\d.]+)');

void main() {
  final root = Directory(
    Platform.environment['OKA_ROOT'] ??
        File.fromUri(Platform.script).parent.parent.parent.path,
  ).absolute;

  final versions = _loadToolchainVersions(root);
  final constraint = versions['dart_sdk_constraint']!;
  final flutterMin = versions['flutter_min']!;

  _assertCiPinsMatchYaml(root, versions);

  var pubspecCount = 0;
  for (final entity in contractPubspecFiles(root)) {
    final content = entity.readAsStringSync();
    final match = _sdkFloorPattern.firstMatch(content);
    if (match == null) continue;
    pubspecCount++;
    final floor = match.group(1)!;
    if (floor == '3.13.0') {
      _fail('stale sdk floor ^3.13.0 in ${entity.path}');
    }
    if (content.contains('sdk: $constraint') == false) {
      _fail('${entity.path} must declare sdk: $constraint');
    }
  }

  final rootPub = File(p.join(root.path, 'pubspec.yaml'));
  if (!rootPub.existsSync() ||
      !rootPub.readAsStringSync().contains('sdk: $constraint')) {
    _fail('root pubspec.yaml must declare sdk: $constraint');
  }

  final dartDoc = RegExp(r'\^3\.14\.0|Dart 3\.14|Dart SDK.*3\.14');
  final flutterDoc = RegExp(r'Flutter 3\.50|flutter_ci_pin.*3\.50|\b3\.50\b');
  for (final docPath in [
    'README.md',
    'docs/FAQ.md',
    'docs/guides/build_and_config.mdx',
    'docs/contributing/contribution_guide.mdx',
  ]) {
    final file = File(p.join(root.path, docPath));
    if (!file.existsSync()) {
      _fail('missing required doc for toolchain gate: $docPath');
    }
    final text = file.readAsStringSync();
    if (!dartDoc.hasMatch(text)) {
      _fail('$docPath must mention Dart ^3.14.0 (or equivalent)');
    }
    if (!flutterDoc.hasMatch(text)) {
      _fail('$docPath must mention Flutter 3.50');
    }
  }

  stdout.writeln(
    'check_toolchain_versions: ok ($pubspecCount pubspecs with sdk floor, '
    'Flutter $flutterMin)',
  );
}
