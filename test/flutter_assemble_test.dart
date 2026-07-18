import 'package:oka/src/build/flutter_assemble.dart';
import 'package:oka/src/config/build_context.dart';
import 'package:test/test.dart';

void main() {
  group('buildFlutterAssembleArgs', () {
    test('debug android application target and defines', () {
      final args = buildFlutterAssembleArgs(
        outputDir: '/tmp/out',
        targetFile: 'lib/main.dart',
        mode: BuildMode.debug,
        targetPlatform: 'android-arm64',
      );

      expect(args.first, 'assemble');
      expect(args, contains('--output'));
      expect(args, contains('/tmp/out'));
      expect(args, contains('-dTargetFile=lib/main.dart'));
      expect(args, contains('-dTargetPlatform=android-arm64'));
      expect(args, contains('-dBuildMode=debug'));
      expect(args, contains('-dTrackWidgetCreation=true'));
      expect(args, contains('debug_android_application'));
      // Must never be flutter build apk
      expect(args, isNot(contains('apk')));
      expect(args.join(' '), isNot(contains('build apk')));
    });

    test('release uses release_android_application without track widgets', () {
      final args = buildFlutterAssembleArgs(
        outputDir: 'out',
        targetFile: 'lib/main.dart',
        mode: BuildMode.release,
        targetPlatform: 'android-arm64',
      );
      expect(args, contains('release_android_application'));
      expect(args, contains('-dBuildMode=release'));
      expect(args, isNot(contains('-dTrackWidgetCreation=true')));
    });
  });

  group('buildFlutterAotAssembleArgs', () {
    test('arm64 aot bundle target', () {
      final args = buildFlutterAotAssembleArgs(
        outputDir: 'aot',
        targetFile: 'lib/main.dart',
        abi: 'arm64-v8a',
      );
      expect(args.first, 'assemble');
      expect(args, contains('android_aot_bundle_release_android-arm64'));
      expect(args, contains('-dTargetPlatform=android-arm64'));
      expect(args, isNot(contains('build')));
    });

    test('armeabi aot target mapping', () {
      final args = buildFlutterAotAssembleArgs(
        outputDir: 'aot',
        targetFile: 'lib/main.dart',
        abi: 'android-arm',
      );
      expect(args, contains('android_aot_bundle_release_android-arm'));
    });
  });

  group('androidApplicationTarget / targetPlatformForAbi', () {
    test('mode targets', () {
      expect(androidApplicationTarget(BuildMode.debug), 'debug_android_application');
      expect(androidApplicationTarget(BuildMode.profile), 'profile_android_application');
      expect(androidApplicationTarget(BuildMode.release), 'release_android_application');
    });

    test('platform mapping', () {
      expect(targetPlatformForAbi('arm64-v8a'), 'android-arm64');
      expect(targetPlatformForAbi('x86_64'), 'android-x64');
    });
  });
}
