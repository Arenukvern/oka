import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

void main() {
  group('ManifestSpec (ADR-0006)', () {
    test('defaults render the legacy manifest byte-for-byte', () {
      final legacy = generateAndroidManifestXml(
        packageName: 'dev.example.app',
        label: 'App',
        minSdk: '21',
        targetSdk: '34',
      );
      final typed = generateAndroidManifestFromSpec(
        packageName: 'dev.example.app',
        label: 'App',
        minSdk: '21',
        targetSdk: '34',
      );
      expect(typed, legacy);
    });

    test('copyWith adds permissions, cleartext, meta-data, activity attrs', () {
      const spec = ManifestSpec();
      final overridden = spec.copyWith(
        permissions: [
          AndroidPermission.internet,
          AndroidPermission.camera,
        ],
        cleartextTraffic: true,
        flutterDeeplinking: true,
        applicationMetaData: const [
          MetaDataSpec(name: 'io.flutter.embedding.android.NormalTheme', resource: '@style/NormalTheme'),
        ],
        activityAttributes: const {'android:launchMode': 'singleTask'},
      );
      final xml = generateAndroidManifestFromSpec(
        packageName: 'dev.example.app',
        label: 'Last Answer',
        minSdk: '25',
        targetSdk: '35',
        spec: overridden,
      );
      expect(xml, contains('android.permission.CAMERA'));
      expect(xml, contains('android:usesCleartextTraffic="true"'));
      expect(xml, contains('flutter_deeplinking_enabled'));
      expect(xml, contains('android:resource="@style/NormalTheme"'));
      expect(xml, contains('android:launchMode="singleTask"'));
      // Original unchanged (immutable value).
      expect(spec.cleartextTraffic, isNull);
      expect(spec.permissions, ['android.permission.INTERNET']);
    });

    test('parses oka.yaml android.manifest section', () {
      final spec = ManifestSpec.fromYamlMap({
        'permissions': ['android.permission.CAMERA'],
        'cleartext_traffic': true,
        'application_attributes': {'android:hardwareAccelerated': 'true'},
      });
      expect(spec.permissions, ['android.permission.CAMERA']);
      expect(spec.cleartextTraffic, isTrue);
      expect(spec.applicationAttributes['android:hardwareAccelerated'], 'true');
    });
  });

  group('SigningConfig (ADR-0006 G2)', () {
    test('fromYamlMap reads env-var password indirection', () {
      final config = SigningConfig.fromYamlMap({
        'keystore': 'keys/release.jks',
        'alias': 'upload',
        'store_password_env': 'OKA_TEST_STORE_PASS',
      });
      expect(config.keystorePath, 'keys/release.jks');
      expect(config.isConfigured, isFalse); // no env var in test env
    });

    test('keyPassword defaults to storePassword', () {
      const config = SigningConfig(
        keystorePath: 'k.jks',
        keyAlias: 'a',
        storePassword: 's3cret',
      );
      expect(config.effectiveKeyPassword, 's3cret');
      expect(config.isConfigured, isTrue);
    });
  });

  group('aapt2 resource configs (ADR-0006 G4)', () {
    test('omits --configs when unset', () {
      final args = buildAapt2LinkArgs(
        androidJar: 'android.jar',
        manifestPath: 'AndroidManifest.xml',
        outputAp: 'out.ap_',
        compiledResourcesZip: 'res.zip',
      );
      expect(args.where((a) => a == '-c'), isEmpty);
    });

    test('emits --configs en,ru when set', () {
      final args = buildAapt2LinkArgs(
        androidJar: 'android.jar',
        manifestPath: 'AndroidManifest.xml',
        outputAp: 'out.ap_',
        compiledResourcesZip: 'res.zip',
        resourceConfigs: const ['en', 'ru'],
      );
      final i = args.indexOf('-c');
      expect(i, greaterThanOrEqualTo(0));
      expect(args[i + 1], 'en,ru');
    });

    test('proto-format link accepts resource configs too', () {
      final args = buildAapt2LinkProtoFormatArgs(
        androidJar: 'android.jar',
        manifestPath: 'AndroidManifest.xml',
        outputAp: 'out.ap_',
        compiledResourcesZip: 'res.zip',
        resourceConfigs: const ['en'],
      );
      expect(args.contains('-c'), isTrue);
    });
  });

  group('dart-defines (ADR-0006 G1)', () {
    test('assemble args carry --define entries', () {
      final args = buildFlutterAssembleArgs(
        outputDir: 'out',
        targetFile: 'lib/main_prod.dart',
        mode: BuildMode.release,
        targetPlatform: 'android-arm64',
        dartDefines: const {'STORE': 'googlePlay', 'FLAVOR': 'prod'},
      );
      expect(args.contains('--define=STORE=googlePlay'), isTrue);
      expect(args.contains('--define=FLAVOR=prod'), isTrue);
      expect(args.contains('-dTargetFile=lib/main_prod.dart'), isTrue);
    });

    test('AOT assemble args carry --define entries', () {
      final args = buildFlutterAotAssembleArgs(
        outputDir: 'out',
        targetFile: 'lib/main_prod.dart',
        abi: 'arm64-v8a',
        dartDefines: const {'STORE': 'rustore'},
      );
      expect(args.contains('--define=STORE=rustore'), isTrue);
    });
  });
}
