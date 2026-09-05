import 'package:test/test.dart';

import 'package:oka_android/src/build/dependency_suggest.dart';

void main() {
  group('extractMissingClass', () {
    test('parses ART "Failed resolution of" form', () {
      const log =
          'java.lang.NoClassDefFoundError: Failed resolution of: Landroidx/collection/SimpleArrayMap;';
      expect(extractMissingClass(log), 'androidx.collection.SimpleArrayMap');
    });

    test('parses plain NoClassDefFoundError descriptor', () {
      const log = 'NoClassDefFoundError: Lkotlinx/coroutines/flow/StateFlowKt;';
      expect(extractMissingClass(log), 'kotlinx.coroutines.flow.StateFlowKt');
    });

    test('parses ClassNotFoundException quoted class', () {
      const log =
          'ClassNotFoundException: Didn\'t find class "com.getkeepsafe.relinker.ReLinker" on path: DexPathList';
      expect(extractMissingClass(log), 'com.getkeepsafe.relinker.ReLinker');
    });

    test('returns null when no missing class present', () {
      expect(extractMissingClass('some other build error'), isNull);
    });
  });

  group('MissingDependencyResolver.suggest (known-class table)', () {
    final resolver = MissingDependencyResolver();

    test('SimpleArrayMap → collection-jvm', () async {
      final s = await resolver.suggest('androidx.collection.SimpleArrayMap');
      expect(s, isNotEmpty);
      expect(s.first.coordinate, 'androidx.collection:collection-jvm:1.4.4');
      expect(s.first.source, 'known-class');
    });

    test('StateFlowKt → coroutines-core-jvm', () async {
      final s = await resolver.suggest('kotlinx.coroutines.flow.StateFlowKt');
      expect(s, isNotEmpty);
      expect(
        s.first.coordinate,
        'org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.9.0',
      );
    });

    test('WindowMetricsCalculator → androidx.window', () async {
      final s = await resolver.suggest(
        'androidx.window.layout.WindowMetricsCalculator',
      );
      expect(s, isNotEmpty);
      expect(s.first.coordinate, 'androidx.window:window:1.3.0');
    });

    test('ReLinker → relinker', () async {
      final s = await resolver.suggest('com.getkeepsafe.relinker.ReLinker');
      expect(s, isNotEmpty);
      expect(s.first.coordinate, 'com.getkeepsafe.relinker:relinker:1.4.5');
    });

    test('unknown class with no cache returns empty', () async {
      final resolver2 = MissingDependencyResolver(cacheRoot: '/nonexistent');
      final s = await resolver2.suggest('com.unknown.pkg.Mystery');
      expect(s, isEmpty);
    });
  });

  group('formatSuggestions', () {
    test('includes coordinate and yaml snippet', () async {
      final resolver = MissingDependencyResolver();
      final s = await resolver.suggest(
        'androidx.window.layout.WindowMetricsCalculator',
      );
      final text = formatSuggestions(
        'androidx.window.layout.WindowMetricsCalculator',
        s,
      );
      expect(text, contains('androidx.window:window:1.3.0'));
      expect(text, contains('extra_deps'));
      expect(text, contains('oka get dep'));
    });

    test('empty suggestions still gives guidance', () {
      final text = formatSuggestions('foo.Bar', const []);
      expect(text, contains('maven.google.com'));
    });
  });
}
