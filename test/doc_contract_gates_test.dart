import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _repoRoot = Directory.current.path;

ProcessResult _runGate(String scriptName, Directory root) =>
    Process.runSync(
      Platform.resolvedExecutable,
      [p.join(_repoRoot, 'tool/contracts', scriptName)],
      environment: {...Platform.environment, 'OKA_ROOT': root.path},
    );

void _writeToolchainYaml(Directory root) {
  Directory(p.join(root.path, 'tool/ci')).createSync(recursive: true);
  File(p.join(root.path, 'tool/ci/toolchain_versions.yaml')).writeAsStringSync('''
dart_sdk_min: "3.14.0"
dart_sdk_constraint: "^3.14.0"
dart_ci_pin: "3.14.1"
flutter_min: "3.50.0"
flutter_ci_pin: "3.50.0"
''');
}

void _writeCiYaml(Directory root, {String dartPin = '3.14.1', String flutterPin = '3.50.0'}) {
  Directory(p.join(root.path, '.github/workflows')).createSync(recursive: true);
  File(p.join(root.path, '.github/workflows/ci.yml')).writeAsStringSync('''
jobs:
  test:
    steps:
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: $dartPin
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: "$flutterPin"
''');
}

void _writeToolchainDocs(Directory root) {
  const body = '''
Dart ^3.14.0 and Flutter 3.50 toolchain.
''';
  File(p.join(root.path, 'README.md')).writeAsStringSync(body);
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
environment:
  sdk: ^3.14.0
''');
  for (final rel in [
    'docs/FAQ.md',
    'docs/guides/build_and_config.mdx',
    'docs/contributing/contribution_guide.mdx',
  ]) {
    File(p.join(root.path, rel)).createSync(recursive: true);
    File(p.join(root.path, rel)).writeAsStringSync(body);
  }
}

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('oka-doc-gate-');
  addTearDown(() => root.deleteSync(recursive: true));
  return root;
}

void main() {
  group('check_doc_assets.dart', () {
    test('passes on real repo', () {
      final result = _runGate('check_doc_assets.dart', Directory(_repoRoot));
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });

    test('fails on SVG with style element', () {
      final root = _tempRoot();
      final svg = Directory(p.join(root.path, 'docs/images'))
        ..createSync(recursive: true);
      File(p.join(svg.path, 'bad.svg')).writeAsStringSync(
        '<svg xmlns="http://www.w3.org/2000/svg"><style>.x{}</style></svg>',
      );
      final result = _runGate('check_doc_assets.dart', root);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('style'));
    });

    test('fails on malformed SVG', () {
      final root = _tempRoot();
      final svg = Directory(p.join(root.path, 'docs/images'))
        ..createSync(recursive: true);
      File(p.join(svg.path, 'bad.svg')).writeAsStringSync('<svg><unclosed>');
      final result = _runGate('check_doc_assets.dart', root);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('malformed'));
    });

    test('fails on missing image path', () {
      final root = _tempRoot();
      File(p.join(root.path, 'README.md')).writeAsStringSync(
        '![x](docs/images/missing.svg)',
      );
      final result = _runGate('check_doc_assets.dart', root);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('missing image'));
    });
  });

  group('check_doc_links.dart', () {
    test('passes on real repo', () {
      final result = _runGate('check_doc_links.dart', Directory(_repoRoot));
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });

    test('fails on broken relative doc link', () {
      final root = _tempRoot();
      Directory(p.join(root.path, 'docs/guides')).createSync(recursive: true);
      File(p.join(root.path, 'docs/guides/bad.mdx')).writeAsStringSync(
        '[x](../missing/target)',
      );
      final result = _runGate('check_doc_links.dart', root);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('broken link'));
    });
  });

  group('check_toolchain_versions.dart', () {
    test('passes on real repo', () {
      final result =
          _runGate('check_toolchain_versions.dart', Directory(_repoRoot));
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });

    test('fails on pubspec with ^3.13.0', () {
      final root = _tempRoot();
      _writeToolchainYaml(root);
      _writeCiYaml(root);
      _writeToolchainDocs(root);
      Directory(p.join(root.path, 'packages/foo')).createSync(recursive: true);
      File(p.join(root.path, 'packages/foo/pubspec.yaml')).writeAsStringSync('''
environment:
  sdk: ^3.13.0
''');
      final result = _runGate('check_toolchain_versions.dart', root);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('3.13.0'));
    });

    test('fails when ci.yml dart pin does not match yaml', () {
      final root = _tempRoot();
      _writeToolchainYaml(root);
      _writeCiYaml(root, dartPin: '9.9.9');
      _writeToolchainDocs(root);
      final result = _runGate('check_toolchain_versions.dart', root);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('ci.yml must pin Dart'));
    });
  });
}
