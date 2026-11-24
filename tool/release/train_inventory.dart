// Single source of truth for the release-train package inventory.
// Consumers: train.dart, publish_order.dart, workspace leak scan, test fixtures.

/// Packages synced on the release train (versions, changelogs, licenses).
const packages = <String>[
  'oka_process',
  'resource_composition',
  'oka_artifacts',
  'oka_core',
  'oka_supervisor',
  'oka_conformance',
  'oka_google_play',
  'oka_app_gallery',
  'oka_android',
  'oka_huawei',
  'oka_rustore',
  'oka_web',
  'oka_desktop',
  'oka_service',
  'oka_harness',
  'oka_update',
  'oka_dart_kernel',
  'oka_verify',
  'oka',
];
