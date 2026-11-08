import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

void main() {
  test('numeric observations compare as integers', () {
    expect(probeObservationMatchesExpect('999', '0'), isFalse);
    expect(probeObservationMatchesExpect('1', '1'), isTrue);
    expect(probeObservationMatchesExpect('"42"', '42'), isTrue);
  });
}
