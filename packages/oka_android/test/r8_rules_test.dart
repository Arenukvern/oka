import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  test('default R8 rules stay vendor-neutral: no dependency-vendor '
      'dontwarns', () {
    // oka defaults cover Flutter-embedding and Android-framework surfaces
    // only. Dependency vendors (Firebase encoders, MLKit, …) are declared
    // per app with `AndroidBuild.r8Rules` — never hardcoded into the
    // platform package.
    expect(defaultR8KeepRules, isNot(contains('firebase')));
    expect(defaultR8KeepRules, isNot(contains('crashlytics')));
    // The only `-dontwarn` targets are the Flutter embedding's own optional
    // surfaces (Play Core deferred components) and the AndroidX family —
    // universal surfaces, not dependency vendors.
    final dontwarns = defaultR8KeepRules
        .split('\n')
        .where((line) => line.startsWith('-dontwarn'))
        .map((line) => line.trim())
        .toList();
    expect(dontwarns, [
      '-dontwarn com.google.android.play.**',
      '-dontwarn androidx.**',
    ]);
  });

  test('composeR8Rules appends app rules after the defaults', () {
    final composed = composeR8Rules(
      extraRules: ['-dontwarn com.google.firebase.encoders.**'],
    );
    expect(composed, contains('-dontwarn com.google.android.play.**'));
    expect(composed, contains('-dontwarn com.google.firebase.encoders.**'));
    // Override order: defaults first, app rules last.
    expect(
      composed.indexOf('-dontwarn androidx.**'),
      lessThan(composed.indexOf('firebase.encoders')),
    );
  });

  test('composeR8Rules with no extra rules is exactly the defaults', () {
    expect(composeR8Rules(), defaultR8KeepRules);
  });
}
