import 'package:oka/src/cli/debug_command.dart';
import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  group('selectStepPrefix', () {
    final steps = AndroidPipeline.defaultSteps;

    test('discovers all default steps by name', () {
      final names = steps.map((s) => s.name).toList();
      expect(names, containsAll(['plugin-packaging', 'compile-and-dex', 'package-and-sign']));
    });

    test('returns a prefix ending at the requested step', () {
      final prefix = selectStepPrefix(steps, 'compile-and-dex')!;
      expect(prefix.last.name, 'compile-and-dex');
      expect(prefix.length, steps.indexOf(steps.firstWhere((s) => s.name == 'compile-and-dex')) + 1);
      // Upstream artifact providers come first.
      expect(prefix.first.name, 'ensure-android-sdk');
    });

    test('whole pipeline when the last step is requested', () {
      final prefix = selectStepPrefix(steps, steps.last.name)!;
      expect(prefix.length, steps.length);
    });

    test('single step when the first step is requested', () {
      final prefix = selectStepPrefix(steps, steps.first.name)!;
      expect(prefix, hasLength(1));
    });

    test('unknown step name returns null', () {
      expect(selectStepPrefix(steps, 'no-such-step'), isNull);
    });
  });
}
