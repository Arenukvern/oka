import 'dart:io';

import 'package:oka/src/build/aapt2_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('buildAapt2CompileDirArgs', () {
    test('uses --dir and writes to a zip file path (not a directory)', () {
      final args = buildAapt2CompileDirArgs(
        resDir: '/proj/res',
        compiledResourcesZip: '/proj/build/compiled_resources.zip',
      );
      expect(args, [
        'compile',
        '--dir',
        '/proj/res',
        '-o',
        '/proj/build/compiled_resources.zip',
      ]);
      expect(args[args.indexOf('-o') + 1], endsWith('.zip'));
      expect(args[args.indexOf('-o') + 1], isNot(endsWith('compiled_res')));
    });
  });

  group('buildAapt2LinkArgs', () {
    test('passes single -R compiled zip (not per-flat files)', () {
      final args = buildAapt2LinkArgs(
        androidJar: '/sdk/platforms/android-34/android.jar',
        manifestPath: '/build/AndroidManifest.xml',
        outputAp: '/build/resources.ap_',
        compiledResourcesZip: '/build/compiled_resources.zip',
        javaOutDir: '/build/gen',
      );
      expect(args.first, 'link');
      expect(args, contains('-I'));
      expect(args, contains('/sdk/platforms/android-34/android.jar'));
      expect(args, contains('--manifest'));
      expect(args, contains('-o'));
      expect(args, contains('/build/resources.ap_'));
      expect(args, contains('--java'));
      expect(args, contains('/build/gen'));
      expect(args, contains('--auto-add-overlay'));

      final rIndexes = <int>[];
      for (var i = 0; i < args.length; i++) {
        if (args[i] == '-R') rIndexes.add(i);
      }
      expect(rIndexes, hasLength(1));
      expect(args[rIndexes.single + 1], '/build/compiled_resources.zip');
      expect(args.where((a) => a.endsWith('.flat')), isEmpty);
    });

    test('optional assets dir', () {
      final args = buildAapt2LinkArgs(
        androidJar: 'android.jar',
        manifestPath: 'AndroidManifest.xml',
        outputAp: 'out.ap_',
        compiledResourcesZip: 'compiled.zip',
        assetsDir: 'assets',
      );
      expect(args, contains('-A'));
      expect(args, contains('assets'));
    });
  });

  group('isCompiledResourcesZipPath', () {
    test('recognizes zip/flata', () {
      expect(isCompiledResourcesZipPath('x/compiled_resources.zip'), isTrue);
      expect(isCompiledResourcesZipPath('x/out.flata'), isTrue);
      expect(isCompiledResourcesZipPath('x/compiled_res'), isFalse);
    });
  });

  test('flutter_apk_builder wires compile zip helpers (source contract)',
      () async {
    final text = await File(
      p.join('lib', 'src', 'build', 'flutter_apk_builder.dart'),
    ).readAsString();
    expect(text, contains('buildAapt2CompileDirArgs'));
    expect(text, contains('buildAapt2LinkArgs'));
    expect(text, contains('compiled_resources.zip'));
    // Old broken pattern: scan directory for .flat after --dir compile
    expect(text, isNot(contains("endsWith('.flat')")));
  });
}
