import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/oka_run_dev.dart';

class FakeApp implements DevApp {
  @override
  final vmUri = Uri.parse('http://127.0.0.1:10000/token=/');
  @override
  void write(String line) {}
  @override
  Future<int> stop() async => 0;
  @override
  Future<String> waitFor(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 90),
  }) async => 'Restarted application';
}

void main() {
  test(
    'declared browser and package policies parse, invalid scope refuses',
    () {
      final args = RunDevArgs.parse([
        '--platform',
        'web',
        '--browser-bin',
        '/chrome',
        '--cdp-port',
        '9229',
        '--browser-headless',
        '--watch-packages',
        'all',
      ], cwd: '/app')!;
      expect(args.browserSpec.binaryPath, '/chrome');
      expect(
        RunDevArgs.parse([
          '--native-vm-uri',
          'http://127.0.0.1:1234/token=/',
        ], cwd: '/app')!.nativeVmUri!.port,
        1234,
      );
      expect(
        RunDevArgs.parse([
          '--platform',
          'web',
          '--native-vm-uri',
          'http://127.0.0.1:1234/',
        ], cwd: '/app'),
        isNull,
      );
      expect(
        RunDevArgs.parse(['--native-vm-uri', 'relative'], cwd: '/app'),
        isNull,
      );
      expect(
        RunDevArgs.parse([
          '--device',
          'iphone',
          '--native-vm-uri',
          'http://127.0.0.1:1234/',
        ], cwd: '/app'),
        isNull,
      );
      expect(args.browserSpec.debugPort, 9229);
      expect(args.browserSpec.headless, isTrue);
      expect(args.packageWatchScope, DevPackageWatchScope.all);
      expect(
        RunDevArgs.parse(['--watch-packages', 'guessed'], cwd: '/app'),
        isNull,
      );
      expect(RunDevArgs.parse(['--cdp-port', '99999'], cwd: '/app'), isNull);
      expect(RunDevArgs.parse([], cwd: '/app')!.browserSpec.debugPort, isNull);
      expect(RunDevArgs.parse([], cwd: '/app')!.browserSpec.headless, isTrue);
      expect(
        RunDevArgs.parse([
          '--open-browser',
          '--browser-visible',
        ], cwd: '/app')!.browserSpec.headless,
        isFalse,
      );
      expect(
        RunDevArgs.parse([
          '--',
          '--no-web-resources-cdn',
        ], cwd: '/app')!.flutterArgs,
        ['--no-web-resources-cdn'],
      );
    },
  );

  test(
    'ready attachment is typed and refreshed after restart without launch',
    () async {
      final app = FakeApp();
      final attachments = <DevSessionAttachment>[];
      var exit = -1;
      await runRunDevCli(
        ['--no-watch'],
        devApp: app,
        commands: Stream.fromIterable(['R', 'q']),
        onSessionReady: attachments.add,
        setExitCode: (code) => exit = code,
        output: (_) {},
        workingDir: '/app',
      );
      expect(exit, 0);
      expect(attachments, hasLength(2));
      expect(attachments.first.app, same(app));
      expect(attachments.last.vmUri, app.vmUri);
      expect(attachments.last.pageWsUrl, isNull);
    },
  );

  test(
    'resolved path dependencies outside project are watched; caches opt in',
    () {
      final temp = Directory.systemTemp.createTempSync('oka-watch-inputs-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final app = Directory('${temp.path}/app')..createSync();
      for (final name in ['app', 'external', 'hosted', 'sdk']) {
        File('${temp.path}/$name/lib/value.dart')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('const value = 1;');
      }
      final config = File('${app.path}/.dart_tool/package_config.json');
      config.parent.createSync();
      config.writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (final name in ['app', 'external', 'hosted', 'sdk'])
              {'name': name, 'rootUri': '../../$name/', 'packageUri': 'lib/'},
          ],
        }),
      );
      File('${app.path}/pubspec.lock').writeAsStringSync('''
packages:
  external:
    source: path
  hosted:
    source: hosted
  sdk:
    source: sdk
''');
      final local = resolveDevWatchFiles(app.path);
      expect(local, contains('${temp.path}/external/lib/value.dart'));
      expect(local, contains('${app.path}/lib/value.dart'));
      expect(local.any((p) => p.contains('/hosted/')), isFalse);
      expect(local.any((p) => p.contains('/sdk/')), isFalse);
      expect(
        resolveDevWatchFiles(
          app.path,
          packageScope: DevPackageWatchScope.project,
        ),
        hasLength(1),
      );
      expect(
        resolveDevWatchFiles(app.path, packageScope: DevPackageWatchScope.all),
        hasLength(4),
      );
      File('${app.path}/pubspec.lock').deleteSync();
      expect(resolveDevWatchFiles(app.path), hasLength(1));
    },
  );
}
