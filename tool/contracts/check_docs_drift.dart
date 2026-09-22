import 'dart:convert';
import 'dart:io';

Never _fail(String message) {
  stderr.writeln('check_docs_drift: $message');
  exit(1);
}

void _requireFileContains(
  Directory root,
  String relativePath,
  String token,
  String label,
) {
  final file = File('${root.path}/$relativePath');
  if (!file.existsSync() || !file.readAsStringSync().contains(token)) {
    _fail("docs drift: '$token' missing from $label (${file.path})");
  }
}

List<String> missingSidebarEntries(Directory root) {
  final config =
      jsonDecode(File('${root.path}/docs.json').readAsStringSync())
          as Map<String, Object?>;
  final missing = <String>[];
  for (final rawGroup in config['sidebar']! as List<Object?>) {
    final group = rawGroup! as Map<String, Object?>;
    for (final rawPage in group['pages']! as List<Object?>) {
      final page = rawPage! as Map<String, Object?>;
      final href = (page['href'] as String?) ?? '';
      if (href.startsWith('http')) continue;

      var path = href.replaceFirst(RegExp('^/+'), '');
      if (path.isEmpty) {
        path = 'index.mdx';
      } else if (!path.split('/').last.contains('.')) {
        path = '$path.mdx';
      }
      if (!File('${root.path}/docs/$path').existsSync()) missing.add(href);
    }
  }
  return missing;
}

String _formatList(Iterable<String> values) =>
    '[${values.map((value) => "'${value.replaceAll("'", r"\'")}'").join(', ')}]';

void main() {
  final root = Directory(
    Platform.environment['OKA_ROOT'] ??
        File.fromUri(Platform.script).parent.parent.parent.path,
  ).absolute;

  _requireFileContains(
    root,
    'AGENTS.md',
    'flutter build apk',
    'AGENTS.md (no-Gradle invariant)',
  );
  _requireFileContains(
    root,
    'docs/start_here/why_this_repo_matters.mdx',
    'never',
    'charter (invariants)',
  );
  for (final key in ['extra_deps', 'extra_assets', 'deeplinks', 'local_aars']) {
    _requireFileContains(
      root,
      'docs/guides/build_and_config.mdx',
      key,
      'build guide (oka.yaml pipeline keys)',
    );
  }
  _requireFileContains(
    root,
    'docs/guides/build_and_config.mdx',
    'icon',
    'build guide (android.icon)',
  );
  _requireFileContains(root, 'README.md', 'docs.page/arenukvern/oka', 'README');

  final missing = missingSidebarEntries(root);
  if (missing.isNotEmpty) {
    _fail('docs.json sidebar entries missing files: ${_formatList(missing)}');
  }
  stdout.writeln('check_docs_drift: docs are in sync');
}
