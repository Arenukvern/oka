import 'toolchain.dart';

export 'toolchain.dart'
    show AndroidToolchain, AndroidxJarProvisioner, ResolvedToolchain, ToolchainEnv;

/// Deprecated: thin wrapper over [ResolvedToolchain] (ADR-0013, T1).
///
/// Tool resolution is now a data-driven, printable policy — see
/// [AndroidToolchain] (the ordered candidate sources) and [ResolvedToolchain]
/// (the artifact injected into steps via `PipelineState`). All `find*`
/// methods delegate with identical semantics; this wrapper exists only until
/// the remaining call sites outside the pipeline migrate. New code must
/// inject [ResolvedToolchain].
class SdkLocator extends ResolvedToolchain {
  SdkLocator({
    super.androidSdkPath,
    super.flutterSdkPath,
    super.verbose,
    super.store,
  });
}
