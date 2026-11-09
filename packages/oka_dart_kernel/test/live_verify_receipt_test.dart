import 'package:oka_dart_kernel/src/gate/live_verify_receipt.dart';
import 'package:test/test.dart';

void main() {
  test('assertLiveVerifyReceiptJson rejects wrong observation values', () {
    const okJson = '''
{
  "ok": true,
  "targets": [
    {
      "probes": [
        {"probe": "devGateSessionTick()", "after": "999", "ok": true}
      ]
    }
  ]
}
''';
    expect(
      assertLiveVerifyReceiptJson(
        okJson,
        probes: [(expression: 'devGateSessionTick()', expect: '0')],
      ),
      isFalse,
    );
  });

  test('assertLiveVerifyReceiptJson requires receipt ok and probe ok', () {
    const badJson = '''
{
  "ok": false,
  "targets": [
    {
      "probes": [
        {"probe": "devGateSessionTick()", "after": "0", "ok": false}
      ]
    }
  ]
}
''';
    expect(
      assertLiveVerifyReceiptJson(
        badJson,
        probes: [(expression: 'devGateSessionTick()', expect: '0')],
      ),
      isFalse,
    );
  });
}
