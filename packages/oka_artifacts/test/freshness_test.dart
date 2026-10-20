import 'dart:io';

import 'package:oka_artifacts/oka_artifacts.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File artifact;
  late Directory lib;

  setUp(() {
    root = Directory.systemTemp.createTempSync('oka-freshness-');
    artifact = File('${root.path}/out.dill')..writeAsStringSync('artifact');
    lib = Directory('${root.path}/pkg/lib')..createSync(recursive: true);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  void source([String content = 'x']) {
    File('${lib.path}/a.dart').writeAsStringSync(content);
  }

  test('missing artifact is stale', () {
    artifact.deleteSync();
    final report = inspectArtifactFreshness(
      artifactPath: artifact.path,
      sourceRoots: [lib.path],
    );
    expect(report.fresh, isFalse);
    expect(report.reason, 'missing');
  });

  test('no newer sources is fresh', () {
    // ensure sources are strictly older than the artifact
    final older = DateTime.now().subtract(const Duration(seconds: 2));
    source();
    File('${lib.path}/a.dart').setLastModifiedSync(older);
    final report = inspectArtifactFreshness(
      artifactPath: artifact.path,
      sourceRoots: [lib.path],
    );
    expect(report.fresh, isTrue);
  });

  test('newer source in a watched root is stale', () {
    final newer = DateTime.now().add(const Duration(seconds: 2));
    source();
    File('${lib.path}/a.dart').setLastModifiedSync(newer);
    final report = inspectArtifactFreshness(
      artifactPath: artifact.path,
      sourceRoots: [lib.path],
    );
    expect(report.fresh, isFalse);
    expect(report.reason, startsWith('sources_newer:'));
  });

  test('newer declared source file is stale', () {
    final src = File('${root.path}/entry.dart')
      ..writeAsStringSync('main() {}')
      ..setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));
    final report = inspectArtifactFreshness(
      artifactPath: artifact.path,
      sourceRoots: [],
      sourceFiles: [src.path],
    );
    expect(report.fresh, isFalse);
    expect(report.reason, 'source_newer:${src.path}');
  });

  test('newer package config is stale', () {
    final config = File('${root.path}/package_config.json')
      ..writeAsStringSync('{}')
      ..setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));
    final report = inspectArtifactFreshness(
      artifactPath: artifact.path,
      sourceRoots: [],
      packageConfigPath: config.path,
    );
    expect(report.fresh, isFalse);
    expect(report.reason, 'package_config_newer');
  });

  test('scanPackageConfigLibs scans libs the config resolves, including '
      'relative rootUris', () {
    // A package outside the scanned roots, referenced relatively from the
    // config's own directory. The config is backdated so only the lib
    // scan can flip freshness.
    final external = Directory('${root.path}/external/pkg/lib')
      ..createSync(recursive: true);
    File('${external.path}/e.dart').writeAsStringSync('e');
    File('${external.path}/e.dart')
        .setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));
    final config = File('${root.path}/.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"ext","rootUri":"../external/pkg","languageVersion":"3.0"}
]}
''')
      ..setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 1)),
      );
    final withoutScan = inspectArtifactFreshness(
      artifactPath: artifact.path,
      sourceRoots: [],
      packageConfigPath: config.path,
    );
    expect(withoutScan.fresh, isTrue);
    final withScan = inspectArtifactFreshness(
      artifactPath: artifact.path,
      sourceRoots: [],
      packageConfigPath: config.path,
      scanPackageConfigLibs: true,
    );
    expect(withScan.fresh, isFalse);
    expect(withScan.reason, startsWith('sources_newer:'));
  });

  test('malformed config yields no roots, stays fresh', () {
    final config = File('${root.path}/package_config.json')
      ..writeAsStringSync('not json {')
      ..setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 1)),
      );
    final report = inspectArtifactFreshness(
      artifactPath: artifact.path,
      sourceRoots: [],
      packageConfigPath: config.path,
      scanPackageConfigLibs: true,
    );
    expect(report.fresh, isTrue);
  });
}
