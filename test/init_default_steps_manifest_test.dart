import 'dart:convert';
import 'dart:io';

import 'package:oka/src/cli/init_command.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka-init-default-steps-');
    await File(p.join(tmp.path, 'pubspec.yaml')).writeAsString(
      'name: my_app\nversion: 2.0.0+3\n',
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'init scaffold defaultSteps run writes run_session.json next to the APK',
    () async {
      await InitCommand(workingDirectory: tmp.path).run([]);

      expect(
        AndroidPipeline.defaultSteps.map((s) => s.name),
        contains('record-run-session'),
      );

      final fakeSdk = p.join(tmp.path, 'fake_flutter');
      final engineRev = File(
        p.join(fakeSdk, 'bin', 'internal', 'engine.version'),
      );
      await engineRev.create(recursive: true);
      await engineRev.writeAsString('f88005a259ba379c2c1156178aa1870936be7b7f');

      final apkPath = p.join(
        tmp.path,
        '.oka_cache',
        'build',
        'debug',
        'app-debug.apk',
      );
      await File(apkPath).create(recursive: true);

      final ctx = BuildContext.fromJson({
        'project_path': tmp.path,
        'build_dir': p.join(tmp.path, '.oka_cache', 'build', 'debug'),
        'mode': 'debug',
        'config': {
          'name': 'my_app',
          'android': {'package_name': 'com.example.my_app', 'min_sdk': 21},
        },
      });
      final state = PipelineState()
        ..apkPath = apkPath
        ..abis = ['arm64-v8a'];

      expect(
        AndroidPipeline.defaultSteps.any((s) => s is RecordRunSessionStep),
        isTrue,
      );
      final result = await RecordRunSessionStep(
        flutterSdkPathOverride: fakeSdk,
      ).run(ctx, state);
      expect(result.ok, isTrue, reason: result.error);

      final manifestPath = p.join(p.dirname(apkPath), runSessionFileName);
      expect(File(manifestPath).existsSync(), isTrue);
      final json =
          jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
      expect(json['application_id'], 'com.example.my_app');
      expect(json['apk_path'], apkPath);
    },
  );
}
