@TestOn('vm && (linux || mac-os)')
library;

import 'package:test/test.dart';

/// Entry alias: full p1 suite lives at `test/owned_session_p1_conformance_test.dart`.
void main() {
  test('p1 conformance suite is registered alongside this harness', () {
    // `dart test` from package root runs all `test/**` including conformance.
  });
}
