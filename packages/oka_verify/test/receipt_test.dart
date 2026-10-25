import 'dart:convert';

import 'package:oka_verify/oka_verify.dart';
import 'package:test/test.dart';

void main() {
  VerifyReceipt receipt({bool pass = true}) => VerifyReceipt(
        revision: 'abc1234567',
        sdkVersion: '3.13.4',
        packageName: 'my_package',
        changedFiles: const <String>['/w/lib/a.dart'],
        selectedSuites: const <String>['/w/test/a_test.dart'],
        rebuiltSuites: const <String>['/w/test/a_test.dart'],
        staleSuites: const <String>['/w/test/a_test.dart'],
        cacheHits: 3,
        pass: pass,
        graphMs: 5,
        rebuildMs: 120,
        runMs: 800,
        refusedFlutterSuites: const <String>['/w/test/w_test.dart'],
        uncoveredChanges: const <String>['/w/pubspec.yaml'],
        broadenReason: 'unknown dependency coverage: /w/pubspec.yaml',
        outputTruncated: true,
        timedOut: true,
      );

  test('the receipt names its own revision and environment', () {
    final json = receipt().toJson();
    expect(json['tool'], 'oka_verify');
    expect(json['revision'], 'abc1234567');
    expect(json['sdkVersion'], '3.13.4');
    expect(json['package'], 'my_package');
  });

  test('the receipt records the refused suites and the widening', () {
    final json = receipt().toJson();
    expect(json['refusedFlutterSuites'], <String>['/w/test/w_test.dart']);
    expect(json['broadenReason'], contains('pubspec.yaml'));
    expect(json['uncoveredChanges'], <String>['/w/pubspec.yaml']);
    expect(json['outputTruncated'], isTrue);
    expect(json['timedOut'], isTrue);
  });

  test('the receipt carries the phase timings', () {
    final json = receipt().toJson();
    final timings = json['timingsMs']! as Map<String, Object?>;
    expect(timings['graph'], 5);
    expect(timings['rebuild'], 120);
    expect(timings['run'], 800);
  });

  test('the receipt encodes as JSON', () {
    final decoded = jsonDecode(receipt().encode()) as Map<String, Object?>;
    expect(decoded['pass'], isTrue);
    expect(decoded['cacheHits'], 3);
  });

  test('a rebuild error is only present when there is one', () {
    expect(receipt().toJson().containsKey('rebuildError'), isFalse);
    final failed = VerifyReceipt(
      revision: 'abc',
      sdkVersion: '3.13.4',
      packageName: 'p',
      changedFiles: const <String>[],
      selectedSuites: const <String>[],
      rebuiltSuites: const <String>[],
      cacheHits: 0,
      pass: false,
      graphMs: 0,
      rebuildMs: 0,
      runMs: 0,
      rebuildError: 'boom',
    );
    expect(failed.toJson()['rebuildError'], 'boom');
  });
}
