import 'dart:io';

import 'package:oka_core/project_operations.dart';
import 'package:test/test.dart';

/// The declaration of a plain static web project: a serve operation over the
/// project root and nothing else.
const String _plainWebDeclaration = '''
{
  "id": "plain_web",
  "operations": [
    {
      "id": "serve",
      "kind": "serve",
      "command": {
        "executable": "python3",
        "arguments": ["-m", "http.server", "8080", "--directory", "."],
        "workingDirectory": {"kind": "project"},
        "timeoutMs": 1800000
      },
      "endpoint": {"host": "127.0.0.1", "port": 8080, "path": "/"},
      "readiness": {"kind": "tcp", "host": "127.0.0.1", "port": 8080}
    }
  ]
}
''';

void main() {
  group('the declaration codec', () {
    test('a declaration decodes into the profile it declares', () {
      final profile = ProjectOperationProfileCodec.decode(_plainWebDeclaration);
      expect(profile.id, 'plain_web');
      expect(profile.operations, hasLength(1));
      final serve = profile.operation(ProjectOperationKind.serve);
      expect(serve, isNotNull);
      expect(serve!.command.argv, <String>[
        'python3',
        '-m',
        'http.server',
        '8080',
        '--directory',
        '.',
      ]);
      expect(serve.command.workingDirectory.kind, ProjectDirectoryKind.project);
      expect(serve.command.timeout, const Duration(minutes: 30));
      expect(serve.endpoint!.toUri().toString(), 'http://127.0.0.1:8080/');
      expect(serve.readiness!.kind, ProjectReadinessKind.tcp);
    });

    test('a profile round-trips through the declaration shape', () {
      const profile = ProjectOperationProfile(
        id: 'fixture',
        operations: <ProjectOperation>[
          ProjectOperation(
            id: 'check',
            kind: ProjectOperationKind.check,
            command: ProjectCommand(
              executable: 'npm',
              arguments: <String>['run', 'build'],
              environment: <String, String>{'CI': '1'},
              timeout: Duration(minutes: 5),
            ),
          ),
        ],
      );
      final text = ProjectOperationProfileCodec.encode(profile);
      final decoded = ProjectOperationProfileCodec.decode(text);
      expect(decoded.toJson(), profile.toJson());
      expect(
        decoded.operation(ProjectOperationKind.check)!.command.environment,
        <String, String>{'CI': '1'},
      );
    });

    test('a shipped fixture is a declaration the codec accepts', () {
      for (final profile in projectOperationProfiles) {
        final decoded = ProjectOperationProfileCodec.decode(
          ProjectOperationProfileCodec.encode(profile),
        );
        expect(decoded.id, profile.id);
        expect(decoded.supports(ProjectOperationKind.check), isTrue);
        expect(decoded.supports(ProjectOperationKind.serve), isTrue);
      }
    });

    test('a refused declaration carries a named reason', () {
      final refused = <String, String>{
        'project_operation_profile_not_json': '{',
        'project_operation_profile_not_object': '[]',
        'project_operation_profile_unknown_key': '{"id":"a","operations":[],"extra":1}',
        'project_operation_profile_invalid_id': '{"id":"a b","operations":[]}',
        'project_operation_profile_no_operations': '{"id":"a","operations":[]}',
        'project_operation_profile_duplicate_operation':
            '{"id":"a","operations":['
            '{"id":"check","kind":"check","command":{"executable":"x"}},'
            '{"id":"check","kind":"build","command":{"executable":"x"}}]}',
        'project_operation_profile_duplicate_kind':
            '{"id":"a","operations":['
            '{"id":"one","kind":"check","command":{"executable":"x"}},'
            '{"id":"two","kind":"check","command":{"executable":"x"}}]}',
        'project_operation_profile_unknown_kind':
            '{"id":"a","operations":['
            '{"id":"one","kind":"lint","command":{"executable":"x"}}]}',
        'project_operation_profile_invalid_directory_kind':
            '{"id":"a","operations":[{"id":"one","kind":"check",'
            '"command":{"executable":"x","workingDirectory":{"kind":"home"}}}]}',
        'project_operation_profile_invalid_directory_path':
            '{"id":"a","operations":[{"id":"one","kind":"check",'
            '"command":{"executable":"x","workingDirectory":{"kind":"external"}}}]}',
        'project_operation_profile_nonpositive_budget':
            '{"id":"a","operations":[{"id":"one","kind":"check",'
            '"command":{"executable":"x","timeoutMs":0}}]}',
        'project_operation_profile_invalid_budget':
            '{"id":"a","operations":[{"id":"one","kind":"check",'
            '"command":{"executable":"x","timeoutMs":"600000"}}]}',
        'project_operation_profile_invalid_endpoint':
            '{"id":"a","operations":[{"id":"one","kind":"serve",'
            '"command":{"executable":"x"},'
            '"endpoint":{"host":"127.0.0.1","port":0}}]}',
        'project_operation_profile_invalid_readiness':
            '{"id":"a","operations":[{"id":"one","kind":"serve",'
            '"command":{"executable":"x"},'
            '"readiness":{"kind":"tcp","host":"127.0.0.1"}}]}',
        'project_operation_profile_invalid_environment':
            '{"id":"a","operations":[{"id":"one","kind":"check",'
            '"command":{"executable":"x","environment":{"TOKEN":1}}}]}',
        'project_operation_profile_invalid_package_root':
            '{"id":"a","operations":[{"id":"one","kind":"check",'
            '"command":{"executable":"x"}}],'
            '"externalPackageRoots":{"deps":"relative/path"}}',
      };
      refused.forEach((reason, declaration) {
        expect(
          () => ProjectOperationProfileCodec.decode(declaration),
          throwsA(
            isA<ProjectOperationProfileFormatException>().having(
              (error) => error.reason,
              'reason',
              reason,
            ),
          ),
          reason: reason,
        );
      });
    });

    test('a refusal never echoes an environment value', () {
      Object? captured;
      try {
        ProjectOperationProfileCodec.decode(
          '{"id":"a","operations":[{"id":"one","kind":"serve",'
          '"command":{"executable":"x","environment":{"SECRET":"s3cr3t-value"}},'
          '"endpoint":{"host":"127.0.0.1","port":0}}]}',
        );
      } on ProjectOperationProfileFormatException catch (error) {
        captured = error.detail;
      }
      expect(captured, isNotNull);
      expect('$captured', isNot(contains('s3cr3t-value')));
    });
  });

  group('the declaration file', () {
    test('a project without a declaration declares nothing', () async {
      final root = await Directory.systemTemp.createTemp('project_decl_');
      addTearDown(() => root.delete(recursive: true));
      expect(
        ProjectOperationProfileCodec.declarationFile(root),
        isNull,
      );
      expect(ProjectOperationProfileCodec.loadDeclaredProfile(root), isNull);
    });

    test('a declared profile is read from the project root', () async {
      final root = await Directory.systemTemp.createTemp('project_decl_');
      addTearDown(() => root.delete(recursive: true));
      final declaration = File(
        '${root.path}/${ProjectOperationProfileCodec.declarationPath}',
      )..createSync(recursive: true);
      declaration.writeAsStringSync(_plainWebDeclaration);
      final profile = ProjectOperationProfileCodec.loadDeclaredProfile(root);
      expect(profile, isNotNull);
      expect(profile!.id, 'plain_web');
      expect(profile.supports(ProjectOperationKind.serve), isTrue);
    });

    test('a refused declaration is refused, not repaired', () async {
      final root = await Directory.systemTemp.createTemp('project_decl_');
      addTearDown(() => root.delete(recursive: true));
      final declaration = File(
        '${root.path}/${ProjectOperationProfileCodec.declarationPath}',
      )..createSync(recursive: true);
      declaration.writeAsStringSync('{"id":"broken","operations":[]}');
      expect(
        () => ProjectOperationProfileCodec.loadDeclaredProfile(root),
        throwsA(
          isA<ProjectOperationProfileFormatException>().having(
            (error) => error.reason,
            'reason',
            'project_operation_profile_no_operations',
          ),
        ),
      );
    });
  });
}
