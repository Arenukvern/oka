import 'package:oka_android/src/build/plugin_discovery.dart';
import 'package:test/test.dart';

void main() {
  group('isKnownUnsupportedPluginName', () {
    test('jni is packable by default (not auto-unsupported)', () {
      expect(isKnownUnsupportedPluginName('jni'), isFalse);
      expect(isKnownUnsupportedPluginName('jni_flutter'), isFalse);
      expect(isKnownUnsupportedPluginName('path_provider_android'), isFalse);
    });

    test('explicit soft-skip list marks names', () {
      expect(
        isKnownUnsupportedPluginName('jni', softSkipNames: {'jni'}),
        isTrue,
      );
    });
  });

  group('decidePluginSupport', () {
    final unsupported = PluginDiscoveryResult(
      plugins: const [
        DiscoveredPlugin(
          name: 'heavy_native',
          path: '/cache/heavy',
          hasAndroid: true,
          unsupportedNative: true,
          unsupportedReason: 'AGP-only',
        ),
        DiscoveredPlugin(
          name: 'path_provider_android',
          path: '/cache/pp',
          hasAndroid: true,
          androidPackage: 'io.flutter.plugins.pathprovider',
          pluginClass: 'PathProviderPlugin',
        ),
      ],
      unsupported: const [
        DiscoveredPlugin(
          name: 'heavy_native',
          path: '/cache/heavy',
          hasAndroid: true,
          unsupportedNative: true,
          unsupportedReason: 'AGP-only',
        ),
      ],
    );

    test('strict mode disallows build when unsupported present', () {
      final d = decidePluginSupport(unsupported, strict: true);
      expect(d.allowBuild, isFalse);
      expect(d.softMode, isFalse);
      expect(d.skipped.map((p) => p.name), contains('heavy_native'));
    });

    test('soft mode allows build and skips unsupported', () {
      final d = decidePluginSupport(unsupported, strict: false);
      expect(d.allowBuild, isTrue);
      expect(d.softMode, isTrue);
      expect(d.skipped.map((p) => p.name), contains('heavy_native'));
      expect(d.warnings.any((w) => w.contains('heavy_native')), isTrue);
    });

    test('PluginDiscovery.ensureSupported throws only when strict', () {
      final discovery = PluginDiscovery();
      expect(
        () => discovery.ensureSupported(unsupported, strict: true),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'msg',
          contains('Unsupported Flutter plugins'),
        )),
      );
      discovery.ensureSupported(unsupported, strict: false);
      final warnings = discovery.softSkipWarnings(unsupported);
      expect(warnings, isNotEmpty);
    });

    test('toRegistrations omits unsupported', () {
      final discovery = PluginDiscovery();
      final regs = discovery.toRegistrations(unsupported);
      expect(regs.map((r) => r.name), isNot(contains('heavy_native')));
      expect(
        regs.any((r) => r.className.contains('PathProvider')),
        isTrue,
      );
    });
  });
}
