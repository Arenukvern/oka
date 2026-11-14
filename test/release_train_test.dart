import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/repo_root.dart';

/// Mirrors [packages] in `tool/release/train.dart` (release-train inventory).
const trainPackages = [
  'oka_process',
  'resource_composition',
  'oka_artifacts',
  'oka_core',
  'oka_supervisor',
  'oka_conformance',
  'oka_android',
  'oka_huawei',
  'oka_play',
  'oka_rustore',
  'oka_web',
  'oka_harness',
  'oka',
];

void main() {
  final repo = findOkaRepoRoot();
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
      'oka_process': [],
      'resource_composition': [],
      'oka_artifacts': ['oka_core'],
      'oka_core': ['resource_composition'],
      'oka_conformance': ['oka_core'],
      'oka_supervisor': ['resource_composition'],
      'oka_android': ['oka_core'],
      'oka_huawei': ['oka_android', 'oka_core'],
      'oka_play': ['oka_core'],
      'oka_rustore': ['oka_core'],
      'oka_web': ['oka_core'],
      'oka_harness': ['oka_android', 'resource_composition'],
      'oka': ['oka_android', 'oka_core'],
    };
    for (final package in trainPackages) {
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
        ...trainPackages.map((name) => 'packages/$name/pubspec.yaml'),
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
      for (final package in trainPackages) {
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

  test('syncs train deps in publish_to:none workspace packages', () {
    write(
      fixture,
      'packages/oka_experimental/pubspec.yaml',
      'name: oka_experimental\n'
      'publish_to: none\n'
      'version: 0.0.1\n'
      'dependencies:\n'
      '  oka_core: ^0.1.6\n'
      'dev_dependencies:\n'
      '  oka_web: ^0.1.6\n',
    );
    final result = run(fixture, 'sync_version.sh', ['--version', '0.3.0']);
    expect(result.exitCode, 0, reason: output(result));
    final experimental =
        File('${fixture.path}/packages/oka_experimental/pubspec.yaml')
            .readAsStringSync();
    expect(
      experimental,
      contains('oka_core: ^0.3.0 # x-release-please-version'),
    );
    expect(
      experimental,
      contains('oka_web: ^0.3.0 # x-release-please-version'),
    );
    expect(
      experimental,
      contains('version: 0.0.1\n'),
      reason: 'non-train package version line stays experimental',
    );
  });

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
    final order = publishList(fixture);
    final fake = fakeTools(fixture);
    final result = runPublish(fixture, fake, '--dry-run');
    expect(result.exitCode, 0, reason: output(result));
    expectFullDartLog(
      fake.log,
      order,
      publishVerb: 'pub publish --dry-run',
      expectOidc: false,
    );
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
    final published =
        publishList(fixture).where((name) => name != 'oka_core').toList();
    expectFullDartLog(fake.log, published, publishVerb: 'pub publish --force');
    expect(output(result), contains('oka_core 0.2.0 already exists'));
    expectOidcCurlContracts(fake.logCurl);
    expect(
      curlLog(fake.logCurl).split('\n').where((line) => line.contains('id-token')).length,
      published.length,
    );
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
    final order = publishList(fixture);
    final failAt = order.indexOf('oka_android');
    expect(failAt, greaterThanOrEqualTo(0));
    final attempted = order.sublist(0, failAt + 1);
    expectFullDartLog(
      fake.log,
      attempted,
      publishVerb: 'pub publish --force',
    );
    expectOidcCurlContracts(fake.logCurl);
  });

  test(
    'publish fails fast when oka_process publish fails (403-class abort)',
    () {
      expect(run(fixture, 'sync_version.sh').exitCode, 0);
      final publishOrder = publishList(fixture);
      expect(publishOrder.first, 'oka_process');

      final fake = fakeTools(fixture);
      final result = runPublish(
        fixture,
        fake,
        '--publish',
        extra: {'OKA_FAKE_DART_FAIL': 'oka_process'},
      );
      expect(result.exitCode, isNot(0), reason: output(result));
      expect(dartPackages(fake.log), ['oka_process']);
      expect(dartPublishInvocations(fake.log), hasLength(1));
      expect(
        dartPublishInvocations(fake.log).single,
        'oka_process|pub publish --force',
      );
      expectFullDartLog(
        fake.log,
        ['oka_process'],
        publishVerb: 'pub publish --force',
      );
    },
  );

  test('list --publish on repo respects in-train dependencies', () {
    final order = publishList(Directory(repo));
    expect(order, isNotEmpty);
    expect(order.first, 'oka_process');
    final index = {for (var i = 0; i < order.length; i++) order[i]: i};
    final trainNames = order.toSet();
    final depLine = RegExp('^  ([a-z][a-z0-9_]*):');
    final sectionHeader = RegExp('^([a-z_]+):');
    for (final name in order) {
      final pubspec = File('$repo/packages/$name/pubspec.yaml');
      final contents = pubspec.readAsStringSync();
      String? section;
      for (final line in contents.split('\n')) {
        if (sectionHeader.hasMatch(line)) {
          section = line.split(':').first;
        }
        if (section != 'dependencies' && section != 'dev_dependencies') {
          continue;
        }
        final dep = depLine.firstMatch(line)?.group(1);
        if (dep == null || !trainNames.contains(dep)) {
          continue;
        }
        final depIndex = index[dep];
        final selfIndex = index[name];
        if (depIndex == null || selfIndex == null) {
          fail('missing $dep or $name in publish order');
        }
        expect(
          depIndex,
          lessThan(selfIndex),
          reason: '$name must publish after $dep',
        );
      }
    }
    final coreIndex = index['oka_core'];
    final artifactsIndex = index['oka_artifacts'];
    if (coreIndex == null || artifactsIndex == null) {
      fail('oka_core or oka_artifacts missing from publish order');
    }
    expect(
      coreIndex,
      lessThan(artifactsIndex),
      reason: 'oka_artifacts depends on hosted oka_core',
    );
  });

  test('list --publish rejects an in-train dependency cycle', () {
    write(
      fixture,
      'packages/resource_composition/pubspec.yaml',
      'name: resource_composition\n'
      'version: 0.1.6 # x-release-please-version\n'
      'dependencies:\n'
      '  oka_core: ^0.1.6\n',
    );
    final result = publishListResult(fixture);
    expect(result.exitCode, isNot(0));
    expect(
      output(result),
      contains('publish order cycle among train packages'),
    );
  });

  test('publish --publish requires OIDC env and never invokes dart publish', () {
    expect(run(fixture, 'sync_version.sh').exitCode, 0);
    final fake = fakeTools(fixture);
    final result = runPublish(
      fixture,
      fake,
      '--publish',
      includeOidc: false,
    );
    expect(result.exitCode, 1);
    expect(
      output(result),
      contains('publish_packages: --publish requires GitHub Actions OIDC env'),
    );
    expect(dartPublishInvocations(fake.log), isEmpty);
  });
}

ProcessResult publishListResult(Directory root) {
  final dart = Process.runSync('sh', [
    '-c',
    'command -v dart',
  ]).stdout.toString().trim();
  return Process.runSync(
    dart,
    ['tool/release/train.dart', 'list', '--publish'],
    workingDirectory: root.path,
    environment: {'OKA_ROOT': root.path},
  );
}

List<String> publishList(Directory root) {
  final dart = Process.runSync('sh', [
    '-c',
    'command -v dart',
  ]).stdout.toString().trim();
  final result = Process.runSync(
    dart,
    ['tool/release/train.dart', 'list', '--publish'],
    workingDirectory: root.path,
    environment: {'OKA_ROOT': root.path},
  );
  expect(result.exitCode, 0, reason: output(result));
  return result.stdout
      .toString()
      .trim()
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toList();
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

const fakeOidcUrl = 'https://fake.actions/id-token?api-version=2.0';
const fakeOidcToken = 'fake-request-token';

({String bin, String log, String logCurl}) fakeTools(Directory fixture) {
  final bin = '${fixture.path}/fake-bin';
  final log = '${fixture.path}/dart.log';
  final logCurl = '${fixture.path}/curl.log';
  Directory(bin).createSync();
  // ignore: leading_newlines_in_multiline_strings
  write(fixture, 'fake-bin/dart', r'''#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == *train.dart ]]; then
  exec "$OKA_REAL_DART" "$@"
fi
if [[ "${1:-}" == "pub" && "${2:-}" == "token" ]]; then
  printf 'oidc|%s\n' "$*" >> "$OKA_FAKE_DART_LOG"
  exit 0
fi
package="${PWD##*/}"
printf '%s|%s\n' "$package" "$*" >> "$OKA_FAKE_DART_LOG"
[[ "${OKA_FAKE_DART_FAIL:-}" != "$package" ]]
''');
  // ignore: leading_newlines_in_multiline_strings
  write(fixture, 'fake-bin/curl', r'''#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$OKA_FAKE_CURL_LOG"
for arg in "$@"; do
  if [[ "$arg" == *"id-token"* ]] || [[ "$arg" == *"fake.actions"* ]]; then
  found_audience=0
  found_bearer=0
  for a in "$@"; do
    [[ "$a" == *audience=https://pub.dev* ]] && found_audience=1
    [[ "$a" == Authorization:*[Bb]earer* ]] && found_bearer=1
  done
  [[ "$found_audience" == 1 ]] || {
    echo "fake-curl: OIDC id-token request missing audience=https://pub.dev" >&2
    exit 3
  }
  [[ "$found_bearer" == 1 ]] || {
    echo "fake-curl: OIDC id-token request missing Authorization: Bearer header" >&2
    exit 3
  }
    echo '{"value":"fake-oidc-token"}'
    exit 0
  fi
done
url="${!#}"
if [[ "$url" == https://pub.dev/api/packages/* ]]; then
  rest="${url#*/packages/}"
  package="${rest%%/versions/*}"
  version="${rest##*/versions/}"
  [[ "$version" == "$(tr -d '[:space:]' < "$OKA_ROOT/VERSION")" ]] || exit 22
  [[ "${OKA_FAKE_PUBLISHED:-}" == *":$package:"* ]] && exit 0
  grep -q "^$package|pub publish --force" "$OKA_FAKE_DART_LOG" 2>/dev/null
  exit $?
fi
echo "fake-curl: unhandled invocation: $*" >&2
exit 2
''');
  Process.runSync('chmod', ['+x', '$bin/dart', '$bin/curl']);
  return (bin: bin, log: log, logCurl: logCurl);
}

ProcessResult runPublish(
  Directory fixture,
  ({String bin, String log, String logCurl}) fake,
  String mode, {
  Map<String, String> extra = const {},
  bool includeOidc = true,
}) => Process.runSync(
  'bash',
  ['tool/release/publish_packages.sh', mode],
  workingDirectory: fixture.path,
  environment: {
    'OKA_ROOT': fixture.path,
    'PATH': '${fake.bin}:${Platform.environment['PATH']}',
    'OKA_FAKE_DART_LOG': fake.log,
    'OKA_FAKE_CURL_LOG': fake.logCurl,
    'OKA_REAL_DART': Process.runSync('sh', [
      '-c',
      'command -v dart',
    ]).stdout.toString().trim(),
    'OKA_PUB_PROPAGATION_WAIT_SECONDS': '1',
    'OKA_PUB_PROPAGATION_TIMEOUT_SECONDS': '2',
    if (includeOidc) 'ACTIONS_ID_TOKEN_REQUEST_URL': fakeOidcUrl,
    if (includeOidc) 'ACTIONS_ID_TOKEN_REQUEST_TOKEN': fakeOidcToken,
    ...extra,
  },
);

List<String> dartPackages(String log) {
  if (!File(log).existsSync()) {
    return [];
  }
  return File(log)
      .readAsLinesSync()
      .where((line) => line.contains('pub publish'))
      .map((line) => line.split('|').first)
      .where((name) => name != 'oidc')
      .toList();
}

List<String> dartLogLines(String log) =>
    File(log).existsSync() ? File(log).readAsLinesSync() : <String>[];

List<String> dartPublishInvocations(String log) => dartLogLines(log)
    .where((line) => line.contains('pub publish'))
    .toList();

int oidcRefreshCount(String log) =>
    dartLogLines(log).where((line) => line.startsWith('oidc|')).length;

String curlLog(String logCurl) =>
    File(logCurl).existsSync() ? File(logCurl).readAsStringSync() : '';

void expectFullDartLog(
  String log,
  List<String> packages, {
  required String publishVerb,
  bool expectOidc = true,
}) {
  final expected = <String>[];
  for (final package in packages) {
    if (expectOidc) {
      expected.add('oidc|pub token add https://pub.dev --env-var PUB_TOKEN');
    }
    expected.add('$package|$publishVerb');
  }
  expect(
    dartLogLines(log),
    expected,
    reason: 'dart invocation log must match the full publish/token sequence',
  );
}

void expectOidcCurlContracts(String logCurl) {
  for (final line in curlLog(logCurl).split('\n').where((line) => line.isNotEmpty)) {
    if (!line.contains('id-token') && !line.contains('fake.actions')) {
      continue;
    }
    expect(
      line,
      contains('audience=https://pub.dev'),
      reason: 'OIDC curl must request audience https://pub.dev',
    );
    expect(
      line,
      matches(RegExp('Authorization: [Bb]earer')),
      reason: 'OIDC curl must send Authorization: Bearer',
    );
  }
}
