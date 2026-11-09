import 'package:oka_android/src/android_artifacts.dart';
import 'package:oka_core/oka_core.dart';

/// Seeds VM-service pipeline artifacts as if [ForwardVmServiceStep] succeeded.
final class SeedVmForwardLaunchStep extends BuildStep {
  SeedVmForwardLaunchStep({
    required this.hostLocalPort,
    this.deviceVmServiceUri = 'http://127.0.0.1:5555/AbCdEfGh=',
  });

  final int hostLocalPort;
  final String deviceVmServiceUri;

  @override
  String get name => 'test-seed-vm-forward';

  @override
  Set<Artifact<Object>> get provides => {vmServiceUri, vmServiceLocalPort};

  @override
  Set<Artifact<Object>> get requires => {};

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    state[vmServiceUri.id] = deviceVmServiceUri;
    state[vmServiceLocalPort.id] = hostLocalPort;
    return StepResult.success({
      vmServiceUri.id: deviceVmServiceUri,
      vmServiceLocalPort.id: hostLocalPort,
    });
  }
}
