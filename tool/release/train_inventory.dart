// Release-train package inventory (single source for `train.dart list`).

/// Packages synced on the release train (versions, changelogs, licenses).
const packages = <String>[
  'oka_process',
  'resource_composition',
  'oka_artifacts',
  'oka_core',
  'oka_supervisor',
  'oka_conformance',
  'oka_android',
  'oka_huawei',
  'oka_play',
  'oka_rustore',
  'oka_web',
  'oka_harness',
  'oka',
];

/// Published to pub.dev by CI (`publish_packages.sh`). `oka_process` is
/// manual-only from the maintainer's Mac — see packages/oka_process/PUBLISHING.md.
const pubDevManualOnly = {'oka_process'};

Iterable<String> packagesForPubDev() =>
    packages.where((p) => !pubDevManualOnly.contains(p));
