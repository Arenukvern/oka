import 'package:oka_android/src/build/provisioning.dart';
import 'package:test/test.dart';

void main() {
  test('provisioned tool guidance covers every oka-managed tool', () {
    // The discovery layer splits `~/.oka/tools` per child with these notes
    // (ADR-0022: Android knowledge lives here, the CLI stays generic).
    final matches = okaProvisionedToolGuidance.map((g) => g.match);
    expect(matches, containsAll(['r8', 'bundletool', 'kotlin']));
    for (final unit in okaProvisionedToolGuidance) {
      expect(unit.guidance, isNotEmpty);
      expect(unit.guidance, contains('oka get'));
    }
    // The guidance matches the actual provisioners: every noun with an
    // install target under ~/.oka/tools has guidance.
    expect(
      androidProvisioners.keys,
      containsAll(['r8', 'bundletool', 'kotlin']),
    );
  });
}
