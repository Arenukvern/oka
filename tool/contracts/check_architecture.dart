import 'dart:convert';
import 'dart:io';

/// Dependency rules are gates; physical line counts are advisory diagnostics.
Map<String, Object?> inspectArchitecture(Directory root) {
  final violations = <Map<String, Object?>>[];
  final hotspots = <Map<String, Object?>>[];
  final packages = Directory('${root.path}/packages');
  if (!packages.existsSync()) throw ArgumentError('Missing packages directory');
  final files =
      packages
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where(
            (file) =>
                file.path.endsWith('.dart') &&
                file.path.contains(
                  '${Platform.pathSeparator}lib${Platform.pathSeparator}',
                ),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final directive = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''');
  for (final file in files) {
    final relative = file.path
        .substring(root.path.length + 1)
        .replaceAll(r'\', '/');
    if (relative.contains('/.dart_tool/') ||
        relative.endsWith('.g.dart') ||
        relative.endsWith('.freezed.dart')) {
      continue;
    }
    final lines = file.readAsLinesSync();
    if (lines.length > 800) {
      hotspots.add({
        'path': relative,
        'lines': lines.length,
        'action':
            'Review responsibility boundaries; size alone is not a failure.',
      });
    }
    final package = relative.split('/')[1];
    for (var line = 0; line < lines.length; line++) {
      final match = directive.firstMatch(lines[line]);
      if (match == null) continue;
      final uri = match.group(1)!;
      final resolved = file.uri.resolve(uri).path.replaceAll(r'\', '/');
      final packagePath = packages.absolute.uri.path;
      final target = uri.startsWith('package:')
          ? uri.substring(8).split('/').first
          : !uri.contains(':') && resolved.startsWith(packagePath)
          ? resolved.substring(packagePath.length).split('/').first
          : null;
      final forbidden = switch (package) {
        'oka_core' || 'oka_conformance' => const {
          'oka',
          'oka_android',
          'oka_web',
          'oka_play',
          'oka_huawei',
        },
        'oka_android' => const {'oka', 'oka_web', 'oka_play', 'oka_huawei'},
        'oka_web' => const {'oka', 'oka_android', 'oka_play', 'oka_huawei'},
        'oka_play' => const {'oka', 'oka_web', 'oka_huawei'},
        'oka_huawei' => const {'oka', 'oka_web', 'oka_play'},
        _ => const <String>{},
      };
      String? reason;
      if (forbidden.contains(target) ||
          (package == 'oka_core' && target == 'oka_conformance')) {
        reason = '$package must not depend on $target';
      }
      if (relative.startsWith('packages/oka/lib/src/cache/')) {
        if (uri.startsWith('package:oka/src/cli/') ||
            resolved.contains('/oka/lib/src/cli/')) {
          reason =
              'Cache application capabilities must not import CLI presentation';
        }
      }
      if (reason != null) {
        violations.add({
          'path': relative,
          'line': line + 1,
          'uri': uri,
          'reason': reason,
        });
      }
    }
  }
  hotspots.sort((a, b) => (b['lines']! as int).compareTo(a['lines']! as int));
  return {
    'schema_version': 'oka.architecture.v1',
    'ok': violations.isEmpty,
    'violations': violations,
    'hotspots': hotspots,
  };
}

void main(List<String> args) {
  if (args.any((arg) => arg != '--json')) {
    stderr.writeln(
      'Usage: dart tool/contracts/check_architecture.dart [--json]',
    );
    exitCode = 64;
    return;
  }
  final report = inspectArchitecture(
    Directory(Platform.environment['OKA_ROOT'] ?? Directory.current.path),
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  if (report['ok'] != true) exitCode = 1;
}
