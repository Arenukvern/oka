/// Builds the gate app's package_config: the app's own entry FIRST (name
/// dedupe wins on first occurrence), then every workspace entry — so the
/// generated app can import `package:oka_update/…` without a pub solve.
///
/// Usage: `dart run tool/s2_gate_appconfig.dart --app-root dir
/// --workspace-config path --out path`.
library;
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  String? appRoot;
  String? workspaceConfig;
  String? out;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--app-root':
        appRoot = args[++i];
      case '--workspace-config':
        workspaceConfig = args[++i];
      case '--out':
        out = args[++i];
    }
  }
  if (appRoot == null || workspaceConfig == null || out == null) {
    stderr.writeln('usage: s2_gate_appconfig.dart --app-root <dir> '
        '--workspace-config <path> --out <path>');
    exitCode = 64;
    return;
  }
  final workspace =
      jsonDecode(File(workspaceConfig).readAsStringSync()) as Map<String, dynamic>;
  final entries =
      (workspace['packages']! as List).cast<Map<String, dynamic>>().toList();
  final appUri = Directory(appRoot).absolute.uri.toString();
  final appEntry = <String, Object?>{
    'name': 'aot_s2_slots',
    'rootUri': appUri,
    'packageUri': 'lib/',
    'languageVersion': '3.12',
  };
  // Root URIs resolve against the SOURCE config's directory — copying a
  // relative `rootUri` into a config that lives elsewhere silently
  // repoints the package (gen_kernel refuses a moved workspace root).
  final sourceBase = File(workspaceConfig).uri;
  String absoluteRoot(Map<String, dynamic> entry) =>
      sourceBase.resolve(entry['rootUri']! as String).toString();
  final merged = [
    appEntry,
    for (final entry in entries)
      if (entry['name'] != appEntry['name'])
        {
          'name': entry['name'],
          'rootUri': absoluteRoot(entry),
          'packageUri': entry['packageUri'],
          if (entry['languageVersion'] != null)
            'languageVersion': entry['languageVersion'],
        },
  ];
  final config = {
    'configVersion': 2,
    'generated': 's2_gate_appconfig.dart',
    'packages': merged,
  };
  File(out).parent.createSync(recursive: true);
  File(out).writeAsStringSync('${jsonEncode(config)}\n');
  stdout.writeln('appconfig: $out (${merged.length} packages)');
}
