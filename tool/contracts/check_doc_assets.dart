import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

Never _fail(String message) {
  stderr.writeln('check_doc_assets: $message');
  exit(1);
}

void _checkSvg(File file) {
  final text = file.readAsStringSync();
  try {
    final doc = XmlDocument.parse(text);
    if (doc.findAllElements('style').isNotEmpty) {
      _fail(
        'SVG must not use <style> (GitHub README sanitizer strips it): '
        '${file.path}',
      );
    }
  } on XmlException catch (e) {
    _fail('malformed SVG XML in ${file.path}: $e');
  }
}

final _mdImagePattern = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');
final _htmlImgPattern = RegExp(
  '<img[^>]+src=["\']([^"\']+)["\']',
  caseSensitive: false,
);

bool _isRemote(String url) =>
    url.startsWith('http://') ||
    url.startsWith('https://') ||
    url.startsWith('data:');

void _checkImageRef(Directory root, File source, String rawUrl) {
  var url = rawUrl.trim();
  if (url.isEmpty || _isRemote(url)) return;
  if (url.startsWith('#')) return;
  final hash = url.indexOf('#');
  if (hash >= 0) url = url.substring(0, hash);

  final baseDir = source.path == p.join(root.path, 'README.md')
      ? root
      : source.parent;
  final resolved = p.normalize(p.join(baseDir.path, url));
  if (!File(resolved).existsSync()) {
    _fail('missing image target ${source.path}: $rawUrl → $resolved');
  }
}

void _scanMarkdownImages(Directory root, File file) {
  final text = file.readAsStringSync();
  for (final pattern in [_mdImagePattern, _htmlImgPattern]) {
    for (final match in pattern.allMatches(text)) {
      _checkImageRef(root, file, match.group(1)!);
    }
  }
}

void main() {
  final root = Directory(
    Platform.environment['OKA_ROOT'] ??
        File.fromUri(Platform.script).parent.parent.parent.path,
  ).absolute;

  final docsImages = Directory(p.join(root.path, 'docs'));
  if (docsImages.existsSync()) {
    docsImages
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.svg'))
        .forEach(_checkSvg);
  }

  _scanMarkdownImages(root, File(p.join(root.path, 'README.md')));
  final docsDir = Directory(p.join(root.path, 'docs'));
  if (docsDir.existsSync()) {
    for (final file in docsDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.mdx') || f.path.endsWith('.md'))) {
      _scanMarkdownImages(root, file);
    }
  }

  stdout.writeln('check_doc_assets: ok');
}
