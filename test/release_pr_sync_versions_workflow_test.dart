import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late String detector;

  setUpAll(() {
    final workflow =
        loadYaml(
              File(
                p.join(
                  Directory.current.path,
                  '.github',
                  'workflows',
                  'release_pr_sync_versions.yml',
                ),
              ).readAsStringSync(),
            )
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final job = jobs['detect-release-pr'] as YamlMap;
    final steps = job['steps'] as YamlList;
    final check = steps.cast<YamlMap>().firstWhere(
      (step) => step['id'] == 'check',
    );
    detector = check['run'] as String;
  });

  Future<String> detect({
    required String title,
    required String head,
    required String headRepository,
  }) async {
    final output = File(
      p.join(
        (await Directory.systemTemp.createTemp('oka-release-pr-test-')).path,
        'output',
      ),
    );
    output.parent.createSync(recursive: true);
    try {
      final result = await Process.run(
        'bash',
        ['-euo', 'pipefail', '-c', detector],
        environment: {
          ...Platform.environment,
          'GITHUB_OUTPUT': output.path,
          'PR_TITLE': title,
          'PR_HEAD': head,
          'PR_HEAD_REPOSITORY': headRepository,
          'BASE_REPOSITORY': 'Arenukvern/oka',
        },
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
      return output.readAsStringSync();
    } finally {
      output.parent.deleteSync(recursive: true);
    }
  }

  test('accepts a same-repository scoped release bot branch', () async {
    expect(
      await detect(
        title: 'chore(oka): release 0.2.0',
        head: 'release-please--branches--main',
        headRepository: 'Arenukvern/oka',
      ),
      contains('is_release_pr=true'),
    );
  });

  test('rejects release-looking pull requests from forks', () async {
    expect(
      await detect(
        title: 'chore: release 0.2.0',
        head: 'release-please--branches--main',
        headRepository: 'attacker/oka',
      ),
      contains('is_release_pr=false'),
    );
  });

  test('keeps shell substitutions in titles inert', () async {
    final marker = File(
      p.join(
        (await Directory.systemTemp.createTemp('oka-release-pr-marker-')).path,
        'executed',
      ),
    );
    try {
      expect(
        await detect(
          title:
              r'$('
              'touch ${marker.path})',
          head: 'release-please--branches--main',
          headRepository: 'Arenukvern/oka',
        ),
        contains('is_release_pr=false'),
      );
      expect(marker.existsSync(), isFalse);
    } finally {
      marker.parent.deleteSync(recursive: true);
    }
  });
}
