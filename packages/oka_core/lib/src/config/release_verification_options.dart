/// Typed, platform-neutral options for post-build delivery verification.
///
/// Platform packages interpret [toolPath], [deviceId], and [activity] for
/// their own delivery tooling. Keeping this contract in oka_core prevents
/// command-line adapters from passing untyped option maps between packages.
class DeliveryVerificationOptions {
  const DeliveryVerificationOptions({
    this.deviceSpecPath,
    this.toolPath,
    this.deviceId,
    this.install = false,
    this.launch = false,
    this.packageName,
    this.activity,
    this.reportPath,
  });

  final String? deviceSpecPath;
  final String? toolPath;
  final String? deviceId;
  final bool install;
  final bool launch;
  final String? packageName;
  final String? activity;
  final String? reportPath;
}

/// Backwards-compatible name for clients which used the pre-delivery
/// terminology. New APIs should use [DeliveryVerificationOptions].
typedef ReleaseVerificationOptions = DeliveryVerificationOptions;
