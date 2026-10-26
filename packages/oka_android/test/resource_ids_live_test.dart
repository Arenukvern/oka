import 'dart:io';

import 'package:oka_android/src/build/sdk_locator.dart';
import 'package:oka_android/src/compilation/resource_compilation.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final sdk = Platform.environment['OKA_ANDROID_SDK'];
  for (final format in AndroidResourceFormat.values) {
    test(
      'library R uses final linked IDs with transitive resources: $format',
      () async {
        final root = await Directory.systemTemp.createTemp('oka_resource_ids_');
        addTearDown(() => root.delete(recursive: true));
        void write(String name, String value) {
          final file = File(p.join(root.path, name));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(value);
        }

        write(
          'base/AndroidManifest.xml',
          '<manifest package="fixture.base"><application/></manifest>',
        );
        write(
          'browser/AndroidManifest.xml',
          '<manifest package="fixture.browser"><application/></manifest>',
        );
        write(
          'base/res/values/attrs.xml',
          '<resources><attr name="alpha" format="float"/></resources>',
        );
        write(
          'browser/res/values/styles.xml',
          '<resources><style name="Dependent"><item name="alpha">0.5</item></style></resources>',
        );
        write(
          'build/res/values/strings.xml',
          '<resources><string name="app_name">Fixture</string></resources>',
        );
        write(
          'build/AndroidManifest.xml',
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="fixture.app"><uses-sdk android:minSdkVersion="25"/><application android:label="@string/app_name"/></manifest>',
        );
        final result = await compileAndroidResources(
          ctx: BuildContext(
            projectPath: root.path,
            buildDir: p.join(root.path, 'build'),
            mode: BuildMode.release,
            config: const OkaConfig({
              'android': {'compile_sdk': '34'},
            }),
          ),
          toolchain: SdkLocator(androidSdkPath: sdk),
          format: format,
          pluginResDirs: [
            p.join(root.path, 'base/res'),
            p.join(root.path, 'browser/res'),
          ],
        );
        expect(result.ok, isTrue, reason: result.error);
        final generated = result.generatedSourcesDir!;
        final app = File(p.join(generated, 'fixture/app/R.java'))
            .readAsStringSync();
        final browser = File(p.join(generated, 'fixture/browser/R.java'))
            .readAsStringSync();
        final base = File(p.join(generated, 'fixture/base/R.java'))
            .readAsStringSync();
        final style = RegExp(r'Dependent\s*=\s*(0x[0-9a-fA-F]+)');
        expect(
          style.firstMatch(browser)?.group(1),
          style.firstMatch(app)?.group(1),
        );
        expect(style.firstMatch(app), isNotNull);
        expect(base, contains(' alpha='));
      },
      skip: sdk == null
          ? 'set OKA_ANDROID_SDK for real aapt2 qualification'
          : false,
    );
  }
}
