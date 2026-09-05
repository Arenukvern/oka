import 'dart:io';

import 'package:oka_android/src/build/engine_artifacts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('EngineArtifacts', () {
    test('extracts libflutter.so from local Flutter SDK flutter.jar', () async {
      // Resolve Flutter SDK via `which flutter`
      final which = await Process.run('which', ['flutter']);
      if (which.exitCode != 0) {
        // ignore: avoid_print
        print('skip: flutter not on PATH');
        return;
      }
      final flutterBin = (which.stdout as String).trim();
      final sdk = p.dirname(p.dirname(flutterBin));
      final jar = File(
        p.join(sdk, 'bin', 'cache', 'artifacts', 'engine', 'android-arm64',
            'flutter.jar'),
      );
      if (!await jar.exists()) {
        // ignore: avoid_print
        print('skip: flutter.jar missing (run flutter precache --android)');
        return;
      }

      final tmp = await Directory.systemTemp.createTemp('oka_engine_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      final engine = EngineArtifacts(sdk);
      final dest = p.join(tmp.path, 'lib', 'arm64-v8a', 'libflutter.so');
      final out = await engine.extractLibflutter(
        abi: 'arm64-v8a',
        destSoPath: dest,
        release: false,
      );
      expect(await File(out).exists(), isTrue);
      expect(await File(out).length(), greaterThan(1000));
    });
  });
}
