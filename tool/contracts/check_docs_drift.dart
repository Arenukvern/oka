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
        // Extension-less hrefs resolve to .mdx first, then .md (the FAQ
        // canonical is docs/FAQ.md).
        final mdx = File('${root.path}/docs/$path.mdx');
        path = mdx.existsSync() ? '$path.mdx' : '$path.md';
      }
      if (!File('${root.path}/docs/$path').existsSync()) missing.add(href);
    }
  }
  return missing;
}

/// Living docs must cite monorepo paths (`packages/<pkg>/lib/src/...`),
/// never the pre-monorepo root-relative form. ADRs, evidence, and archive
/// pages are historical records — they may describe where code lived at
/// the time and are exempt.
List<String> rootLevelLibCitations(Directory root) {
  final offenders = <String>[];
  final docFiles = <File>[
    File('${root.path}/README.md'),
    File('${root.path}/AGENTS.md'),
    File('${root.path}/llms.txt'),
  ];
  for (final dir in ['guides', 'start_here']) {
    final d = Directory('${root.path}/docs/$dir');
    if (!d.existsSync()) continue;
    docFiles.addAll(
      d.listSync(recursive: true).whereType<File>().where(
            (f) => f.path.endsWith('.md') || f.path.endsWith('.mdx'),
          ),
    );
  }
  for (final file in docFiles) {
    if (!file.existsSync()) continue;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.contains('lib/src/') && !line.contains('packages/')) {
        offenders.add('${file.path}:${i + 1}');
      }
    }
  }
  return offenders;
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

  // docs.page serves everything under docs/ — exactly one FAQ (the .md
  // canonical) and no internal work-log lanes may exist in the public tree.
  if (File('${root.path}/docs/FAQ.mdx').existsSync()) {
    _fail(
      'docs drift: docs/FAQ.mdx exists — docs/FAQ.md is the canonical FAQ; '
      'docs.page would serve the twin and the two would drift',
    );
  }
  if (Directory('${root.path}/docs/validation').existsSync()) {
    _fail(
      'docs drift: docs/validation/ exists — internal work-logs must not be '
      'publicly served; move them to docs/evidence/ (condensed) or out of docs/',
    );
  }

  final citations = rootLevelLibCitations(root);
  if (citations.isNotEmpty) {
    _fail(
      'docs drift: root-relative lib/src/ citations (pre-monorepo paths) in: '
      '${_formatList(citations)} — cite packages/<pkg>/lib/src/... instead',
    );
  }
  stdout.writeln('check_docs_drift: docs are in sync');
}
