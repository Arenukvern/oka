import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const packages = [
  'oka_core',
  'oka_conformance',
  'oka_android',
  'oka_huawei',
  'oka_play',
  'oka_rustore',
  'oka_web',
  'oka',
];

void main() {
  final repo = Directory.current.path;
  late Directory fixture;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('oka_release_train_');
    write(fixture, 'VERSION', '0.2.0\n');
    write(
      fixture,
      'pubspec.yaml',
      'name: oka_workspace\ndev_dependencies:\n  oka: ^0.1.6\n  oka_android: ^0.1.6\n',
    );
    write(
      fixture,
      'example/pubspec.yaml',
      'name: example\ndependencies:\n  oka: ^0.1.6\n  oka_play: ^0.1.6\n',
    );
    final dependencies = <String, List<String>>{
      'oka_core': [],
      'oka_conformance': ['oka_core'],
      'oka_android': ['oka_core'],
      'oka_huawei': ['oka_android', 'oka_core'],
      'oka_play': ['oka_core'],
      'oka_rustore': ['oka_core'],
      'oka_web': ['oka_core'],
      'oka': ['oka_android', 'oka_core'],
    };
    for (final package in packages) {
      final deps = dependencies[package]!
          .map((name) => '  $name: ^0.1.6')
          .join('\n');
      write(
        fixture,
        'packages/$package/pubspec.yaml',
        'name: $package\nversion: 0.1.6 # x-release-please-version\n${deps.isEmpty ? '' : 'dependencies:\n$deps\n'}',
      );
    }
    write(
      fixture,
      'packages/oka/lib/src/version.dart',
      "const String version = '0.1.6';\n",
    );
    write(
      fixture,
      'plugin/.cursor-plugin/plugin.json',
      '{"name":"cursor","version":"0.1.6","metadata":{"version":"keep-cursor"}}',
    );
    write(
      fixture,
      'plugin/.codex-plugin/plugin.json',
      '{"name":"codex","metadata":{"version":"keep-codex"},"version":"0.1.6"}',
    );
    write(
      fixture,
      'plugin/.claude-plugin/plugin.json',
      '{"version":"0.1.6","nested":{"version":"keep-claude"}}',
    );
    write(
      fixture,
      '.claude-plugin/marketplace.json',
      '{"version":"keep-marketplace","plugins":[{"name":"oka","version":"0.1.6","metadata":{"version":"keep-plugin"}}]}',
    );
    for (final script in [
      'train.dart',
      'sync_version.sh',
      'check_version_sync.sh',
      'publish_packages.sh',
    ]) {
      write(
        fixture,
        'tool/release/$script',
        File('$repo/tool/release/$script').readAsStringSync(),
      );
    }
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  test(
    'syncs future version through packages, dependencies, and manifests',
    () {
      final result = run(fixture, 'sync_version.sh', ['--version', '0.3.0']);
      expect(result.exitCode, 0, reason: output(result));
      expect(File('${fixture.path}/VERSION').readAsStringSync(), '0.3.0\n');
      for (final path in [
        'pubspec.yaml',
        'example/pubspec.yaml',
        ...packages.map((name) => 'packages/$name/pubspec.yaml'),
      ]) {
        final contents = File('${fixture.path}/$path').readAsStringSync();
        expect(contents, isNot(contains('^0.1.6')), reason: path);
        for (final match in RegExp(
          r'^\s+(oka(?:_[a-z_]+)?):\s*(\S+)',
          multiLine: true,
        ).allMatches(contents)) {
          expect(match.group(2), '^0.3.0', reason: '$path: ${match.group(1)}');
        }
      }
      for (final package in packages) {
        expect(
          File(
            '${fixture.path}/packages/$package/pubspec.yaml',
          ).readAsStringSync(),
          contains('version: 0.3.0 # x-release-please-version'),
        );
      }
      expect(
        File(
          '${fixture.path}/packages/oka/lib/src/version.dart',
        ).readAsStringSync(),
        contains("const String version = '0.3.0';"),
      );
      for (final entry in {
        'plugin/.cursor-plugin/plugin.json': 'keep-cursor',
        'plugin/.codex-plugin/plugin.json': 'keep-codex',
        'plugin/.claude-plugin/plugin.json': 'keep-claude',
      }.entries) {
        final json =
            jsonDecode(File('${fixture.path}/${entry.key}').readAsStringSync())
                as Map<String, dynamic>;
        expect(json['version'], '0.3.0');
        final nested =
            (json['metadata'] ?? json['nested']) as Map<String, dynamic>;
        expect(nested['version'], entry.value);
      }
      final marketplace =
          jsonDecode(
                File(
                  '${fixture.path}/.claude-plugin/marketplace.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(marketplace['version'], 'keep-marketplace');
      final plugin =
          (marketplace['plugins'] as List).single as Map<String, dynamic>;
      expect(plugin['version'], '0.3.0');
      expect(
        (plugin['metadata'] as Map<String, dynamic>)['version'],
        'keep-plugin',
      );
      final check = run(fixture, 'check_version_sync.sh');
      expect(check.exitCode, 0, reason: output(check));
    },
  );

  test('rejects invalid version without mutating VERSION', () {
    final before = File('${fixture.path}/VERSION').readAsBytesSync();
    final result = run(fixture, 'sync_version.sh', [
      '--version',
      'future0.3.0',
    ]);
    expect(result.exitCode, isNot(0));
    expect(File('${fixture.path}/VERSION').readAsBytesSync(), before);
  });

  test('fails when a required manifest is missing', () {
    File('${fixture.path}/plugin/.codex-plugin/plugin.json').deleteSync();
    final result = run(fixture, 'sync_version.sh');
    expect(result.exitCode, isNot(0));
    expect(output(result), contains('plugin/.codex-plugin/plugin.json'));
  });

  test('reports the specific package that drifts after sync', () {
    expect(run(fixture, 'sync_version.sh').exitCode, 0);
    final file = File('${fixture.path}/packages/oka_play/pubspec.yaml');
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst('version: 0.2.0', 'version: 9.9.9'),
    );
    final result = run(fixture, 'check_version_sync.sh');
    expect(result.exitCode, isNot(0));
    expect(output(result), contains('packages/oka_play/pubspec.yaml'));
  });

  test('publish dry-run executes every package in dependency order', () {
    expect(run(fixture, 'sync_version.sh').exitCode, 0);
    final fake = fakeTools(fixture);
    final result = runPublish(fixture, fake, '--dry-run');
    expect(result.exitCode, 0, reason: output(result));
    expect(dartPackages(fake.log), packages);
  });

  test('publish resumes past an exact version already on pub.dev', () {
    expect(run(fixture, 'sync_version.sh').exitCode, 0);
    final fake = fakeTools(fixture);
    final result = runPublish(
      fixture,
      fake,
      '--publish',
      extra: {'OKA_FAKE_PUBLISHED': ':oka_core:'},
    );
    expect(result.exitCode, 0, reason: output(result));
    expect(dartPackages(fake.log), packages.skip(1).toList());
    expect(output(result), contains('oka_core 0.2.0 already exists'));
  });

  test('publish aborts immediately when dart publish fails', () {
    expect(run(fixture, 'sync_version.sh').exitCode, 0);
    final fake = fakeTools(fixture);
    final result = runPublish(
      fixture,
      fake,
      '--publish',
      extra: {'OKA_FAKE_DART_FAIL': 'oka_android'},
    );
    expect(result.exitCode, isNot(0));
    expect(dartPackages(fake.log), [
      'oka_core',
      'oka_conformance',
      'oka_android',
    ]);
  });
}

void write(Directory fixture, String path, String contents) {
  final file = File('${fixture.path}/$path')..createSync(recursive: true);
  file.writeAsStringSync(contents);
}

ProcessResult run(
  Directory fixture,
  String script, [
  List<String> args = const [],
]) => Process.runSync(
  'bash',
  ['tool/release/$script', ...args],
  workingDirectory: fixture.path,
  environment: {'OKA_ROOT': fixture.path},
);

String output(ProcessResult result) => '${result.stdout}\n${result.stderr}';

({String bin, String log}) fakeTools(Directory fixture) {
  final bin = '${fixture.path}/fake-bin';
  final log = '${fixture.path}/dart.log';
  Directory(bin).createSync();
  // ignore: leading_newlines_in_multiline_strings
  write(fixture, 'fake-bin/dart', r'''#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == *train.dart ]]; then
  exec "$OKA_REAL_DART" "$@"
fi
package="${PWD##*/}"
printf '%s|%s\n' "$package" "$*" >> "$OKA_FAKE_DART_LOG"
[[ "${OKA_FAKE_DART_FAIL:-}" != "$package" ]]
''');
  // ignore: leading_newlines_in_multiline_strings
  write(fixture, 'fake-bin/curl', r'''#!/usr/bin/env bash
set -eu
url="${!#}"
rest="${url#*/packages/}"
package="${rest%%/versions/*}"
version="${rest##*/versions/}"
[[ "$version" == "$(tr -d '[:space:]' < "$OKA_ROOT/VERSION")" ]] || exit 22
[[ "${OKA_FAKE_PUBLISHED:-}" == *":$package:"* ]] && exit 0
grep -q "^$package|pub publish --force" "$OKA_FAKE_DART_LOG" 2>/dev/null
''');
  Process.runSync('chmod', ['+x', '$bin/dart', '$bin/curl']);
  return (bin: bin, log: log);
}

ProcessResult runPublish(
  Directory fixture,
  ({String bin, String log}) fake,
  String mode, {
  Map<String, String> extra = const {},
}) => Process.runSync(
  'bash',
  ['tool/release/publish_packages.sh', mode],
  workingDirectory: fixture.path,
  environment: {
    'OKA_ROOT': fixture.path,
    'PATH': '${fake.bin}:${Platform.environment['PATH']}',
    'OKA_FAKE_DART_LOG': fake.log,
    'OKA_REAL_DART': Process.runSync('sh', [
      '-c',
      'command -v dart',
    ]).stdout.toString().trim(),
    'OKA_PUB_PROPAGATION_WAIT_SECONDS': '1',
    'OKA_PUB_PROPAGATION_TIMEOUT_SECONDS': '2',
    ...extra,
  },
);

List<String> dartPackages(String log) =>
    File(log).readAsLinesSync().map((line) => line.split('|').first).toList();
