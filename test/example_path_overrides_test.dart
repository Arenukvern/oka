import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../tool/contracts/check_example_path_overrides.dart' as overrides;
import 'support/repo_root.dart';

void main() {
  group('example path-override closure', () {
    test('real example covers reachable workspace packages', () {
      final root = Directory(findOkaRepoRoot());
      expect(overrides.missingExamplePathOverrides(root), isEmpty);
    });

    test('reports missing overrides for transitive train packages', () {
      final root = Directory.systemTemp.createTempSync('oka-override-guard-');
      addTearDown(() => root.deleteSync(recursive: true));

      Directory('${root.path}/packages/oka_supervisor').createSync(
        recursive: true,
      );
      Directory('${root.path}/packages/resource_composition').createSync(
        recursive: true,
      );

      File('${root.path}/packages/oka_supervisor/pubspec.yaml').writeAsStringSync(
        '''
name: oka_supervisor
dependencies:
  resource_composition: ^99.0.0
''',
      );
      File('${root.path}/packages/resource_composition/pubspec.yaml')
          .writeAsStringSync('name: resource_composition\n');

      Directory('${root.path}/example').createSync();
      File('${root.path}/example/pubspec.yaml').writeAsStringSync(
        '''
name: example
environment:
  sdk: ^3.13.0
dependencies:
  oka_supervisor: ^0.9.0
dependency_overrides:
  oka_supervisor:
    path: ../packages/oka_supervisor
''',
      );

      expect(
        overrides.missingExamplePathOverrides(root),
        ['resource_composition'],
      );
    });

    test('requires path override for hosted direct workspace dependency', () {
      final root = Directory.systemTemp.createTempSync('oka-override-hosted-');
      addTearDown(() => root.deleteSync(recursive: true));

      Directory('${root.path}/packages/oka').createSync(recursive: true);
      File('${root.path}/packages/oka/pubspec.yaml').writeAsStringSync(
        'name: oka\ndependencies:\n  meta: ^1.0.0\n',
      );

      Directory('${root.path}/example').createSync();
      File('${root.path}/example/pubspec.yaml').writeAsStringSync(
        '''
name: example
dependencies:
  oka: ^99.0.0
dependency_overrides:
''',
      );

      expect(overrides.missingExamplePathOverrides(root), ['oka']);
    });

    test('reachable closure follows dependencies only', () {
      final root = Directory.systemTemp.createTempSync('oka-override-closure-');
      addTearDown(() => root.deleteSync(recursive: true));

      Directory('${root.path}/packages/oka_web').createSync(recursive: true);
      Directory('${root.path}/packages/oka_conformance').createSync(
        recursive: true,
      );

      File('${root.path}/packages/oka_web/pubspec.yaml').writeAsStringSync(
        '''
name: oka_web
dependencies:
  meta: ^1.0.0
dev_dependencies:
  oka_conformance: ^0.9.0
''',
      );
      File('${root.path}/packages/oka_conformance/pubspec.yaml')
          .writeAsStringSync('name: oka_conformance\n');

      final exampleFile = File('${root.path}/example/pubspec.yaml');
      exampleFile.parent.createSync(recursive: true);
      exampleFile.writeAsStringSync(
        '''
name: example
dependencies:
  oka_web: ^0.9.0
dependency_overrides:
  oka_web:
    path: ../packages/oka_web
''',
      );

      final pubspec = loadYaml(exampleFile.readAsStringSync());
      expect(pubspec, isA<YamlMap>());
      expect(
        overrides.reachableWorkspacePackages(root, pubspec as YamlMap),
        {'oka_web'},
      );
      expect(overrides.missingExamplePathOverrides(root), isEmpty);
    });
  });
}
