import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:test/test.dart';

const feature = SlotFamily(
  name: 'feature',
  contractType: 'String Function()',
  revisions: [
    SlotRevision(id: 'r1', importUri: 'units/feature_r1.dart', member: 'feature'),
    SlotRevision(id: 'r2', importUri: 'units/feature_r2.dart', member: 'feature'),
  ],
);

void main() {
  test('emits deferred slot imports and the registry indirection', () {
    final source = emitSlotRegistrySource(
        const SlotProvision(families: [feature]));
    expect(source, contains(
        "import 'units/feature_r1.dart' deferred as slot_feature_r1;"));
    expect(source, contains(
        "import 'units/feature_r2.dart' deferred as slot_feature_r2;"));
    // The one-line indirection (ADR-0035 §S2): call sites bind the registry.
    expect(source, contains('String Function() get featureUnit => '
        '_featureLoaded ??'));
    expect(source, contains('set featureUnit(String Function() value) => '
        '_featureLoaded = value;'));
    expect(
        source, contains('String get featureRevision => _featureRevision;'));
    expect(source, contains("const List<String> featureSlotRevisions = ['r1', 'r2'];"));
    // Loaders flip the pointer per revision slot.
    expect(source, contains('await slot_feature_r1.loadLibrary();'));
    expect(source, contains('featureUnit = slot_feature_r1.feature;'));
    expect(source, contains('await slot_feature_r2.loadLibrary();'));
    expect(source, contains('Future<void> loadFeatureSlot(String revision) '
        'async {'));
  });

  test('emission is byte-stable for equal provisions', () {
    final a = emitSlotRegistrySource(
        const SlotProvision(families: [feature]));
    final b = emitSlotRegistrySource(
        const SlotProvision(families: [feature]));
    expect(a, b);
    expect(a.split('\n').length, greaterThan(20));
  });

  test('snake_case families camel-case generated identifiers', () {
    expect(camelCaseFamily('audio_mixer'), 'audioMixer');
    expect(pascalCaseFamily('audio_mixer'), 'AudioMixer');
    const family = SlotFamily(
      name: 'audio_mixer',
      contractType: 'String Function()',
      revisions: [
        SlotRevision(id: 'r1', importUri: 'units/r1.dart', member: 'mix'),
      ],
    );
    final source =
        emitSlotRegistrySource(const SlotProvision(families: [family]));
    expect(source, contains('String Function() get audioMixerUnit => '
        '_audioMixerLoaded ??'));
    expect(source, contains('loadAudioMixerSlot'));
    expect(source, contains('slot_audio_mixer_r1.loadLibrary();'));
  });

  test('unprovisioned revision refusal names the provisioned set', () {
    final source = emitSlotRegistrySource(
        const SlotProvision(families: [feature]));
    // Regression: the refusal string interpolates `$revision` inside the
    // GENERATED code and lists ids WITHOUT quotes (they sit inside a
    // single-quoted generated string).
    expect(source, contains(r'`$revision` (provisioned: r1, r2)'));
    expect(source, isNot(contains("(provisioned: 'r1'")));
  });

  group('fail-closed provisions', () {
    SlotProvision provision(SlotFamily family) =>
        SlotProvision(families: [family]);

    test('no families', () {
      expect(() => emitSlotRegistrySource(const SlotProvision(families: [])),
          throwsA(isA<SlotRegistryException>()));
    });

    test('bad family name', () {
      expect(
          () => emitSlotRegistrySource(provision(SlotFamily(
              name: 'Feature', contractType: 'int', revisions: [
                feature.revisions.first,
              ]))),
          throwsA(isA<SlotRegistryException>()));
    });

    test('contract type with a single quote', () {
      expect(
          () => emitSlotRegistrySource(provision(SlotFamily(
              name: 'feature',
              contractType: "String Function('x')",
              revisions: feature.revisions))),
          throwsA(isA<SlotRegistryException>()));
    });

    test('duplicate revision id', () {
      expect(
          () => emitSlotRegistrySource(provision(SlotFamily(
              name: 'feature',
              contractType: 'int',
              revisions: [
                feature.revisions.first,
                feature.revisions.first,
              ]))),
          throwsA(isA<SlotRegistryException>()));
    });

    test('bad revision id', () {
      expect(
          () => emitSlotRegistrySource(provision(const SlotFamily(
              name: 'feature',
              contractType: 'int',
              revisions: [
                SlotRevision(id: 'R1', importUri: 'u.dart', member: 'f'),
              ]))),
          throwsA(isA<SlotRegistryException>()));
    });

    test('bad member identifier', () {
      expect(
          () => emitSlotRegistrySource(provision(const SlotFamily(
              name: 'feature',
              contractType: 'int',
              revisions: [
                SlotRevision(id: 'r1', importUri: 'u.dart', member: 'a b'),
              ]))),
          throwsA(isA<SlotRegistryException>()));
    });

    test('empty revision list', () {
      expect(
          () => emitSlotRegistrySource(provision(const SlotFamily(
              name: 'feature', contractType: 'int', revisions: []))),
          throwsA(isA<SlotRegistryException>()));
    });
  });
}
