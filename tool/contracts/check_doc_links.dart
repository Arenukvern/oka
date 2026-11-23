import 'dart:io';

import 'package:path/path.dart' as p;

Never _fail(String message) {
  stderr.writeln('check_doc_links: $message');
  exit(1);
}

final _linkPattern = RegExp(r'\[[^\]]*\]\(([^)]+)\)');

bool _isExternal(String url) =>
    url.startsWith('http://') ||
    url.startsWith('https://') ||
    url.startsWith('mailto:');

File? _resolveDocTarget(Directory root, File source, String rawPath) {
  var pathPart = rawPath;
  if (pathPart.isEmpty) return source;
  if (pathPart.startsWith('/')) {
    pathPart = pathPart.replaceFirst(RegExp('^/+'), '');
    if (pathPart.isEmpty) {
      return File(p.join(root.path, 'docs/index.mdx'));
    }
    final docsBase = p.join(root.path, 'docs', pathPart);
    if (File(docsBase).existsSync()) return File(docsBase);
    final lastSeg = p.basename(pathPart);
    if (!lastSeg.contains('.')) {
      final mdx = File('$docsBase.mdx');
      if (mdx.existsSync()) return mdx;
      final md = File('$docsBase.md');
      if (md.existsSync()) return md;
    }
    return null;
  }

  final base = source.parent;
  final candidate = p.normalize(p.join(base.path, pathPart));
  if (File(candidate).existsSync()) return File(candidate);
  final lastSeg = p.basename(pathPart);
  if (!lastSeg.contains('.')) {
    final mdx = File('$candidate.mdx');
    if (mdx.existsSync()) return mdx;
    final md = File('$candidate.md');
    if (md.existsSync()) return md;
  }
  return null;
}

void _checkFile(Directory root, File file) {
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    for (final match in _linkPattern.allMatches(line)) {
      var url = match.group(1)!.trim();
      if (url.isEmpty || _isExternal(url)) continue;
      if (url.startsWith('#')) {
        continue;
      }

      final hash = url.indexOf('#');
      if (hash >= 0) {
        url = url.substring(0, hash);
      }

      if (!url.startsWith('/')) {
        final repoTarget = p.normalize(p.join(file.parent.path, url));
        if (File(repoTarget).existsSync() ||
            Directory(repoTarget).existsSync()) {
          continue;
        }
      }

      if (file.path.endsWith('README.md') && !url.startsWith('/')) {
        final repoTarget = p.normalize(p.join(root.path, url));
        if (!File(repoTarget).existsSync() &&
            !Directory(repoTarget).existsSync()) {
          _fail('${file.path}:${i + 1}: broken link → $url');
        }
        continue;
      }

      final target = _resolveDocTarget(root, file, url);
      if (target == null) {
        _fail('${file.path}:${i + 1}: broken link → $url');
      }
    }
  }
}

void main() {
  final root = Directory(
    Platform.environment['OKA_ROOT'] ??
        File.fromUri(Platform.script).parent.parent.parent.path,
  ).absolute;

  _checkFile(root, File(p.join(root.path, 'README.md')));
  final docsDir = Directory(p.join(root.path, 'docs'));
  if (docsDir.existsSync()) {
    for (final file in docsDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.mdx') || f.path.endsWith('.md'))) {
      final rel = p.relative(file.path, from: root.path).replaceAll(r'\', '/');
      if (rel.startsWith('docs/archive/')) continue;
      _checkFile(root, file);
    }
  }

  stdout.writeln('check_doc_links: ok');
}
