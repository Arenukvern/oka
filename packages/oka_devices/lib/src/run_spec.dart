/// Top-level dev session declaration.
library;

import 'package:meta/meta.dart';

import 'app_spec.dart';
import 'device_spec.dart';
import 'port_choice.dart';
import 'port_plan.dart';
import 'spec_violation.dart';

/// Declarative dev run (device + app + ports + teardown budget).
@immutable
final class RunSpec with TypedSpec {
  const RunSpec({
    required this.device,
    required this.app,
    required this.ports,
    this.teardownBudget = const Duration(seconds: 30),
    this.publishRunnerSession = true,
  });

  final DeviceSpec device;
  final AppSpec app;
  final PortPlan ports;
  final Duration teardownBudget;
  final bool publishRunnerSession;

  /// Flutter `attach -d` device id.
  String get attachDeviceId => device.flutterDeviceId;

  @override
  List<String> validate() {
    final problems = <String>[
      ...device.validate(),
      ...app.validate(),
      ...ports.validate(),
      ..._validateTeardownBudget(),
    ];
    return problems;
  }

  List<String> _validateTeardownBudget() {
    if (teardownBudget.isNegative) {
      return ['teardownBudget must not be negative'];
    }
    return const [];
  }

  /// Flutter `attach --machine` argv from declared ports.
  ///
  /// Token spelling matches [flutterAttachMachineArgs] in `oka_android`
  /// (separate `--flag` / value tokens).
  List<String> plan() {
    final hostVmServicePort = switch (ports.hostVmService) {
      FixedPort(:final port) when port > 0 => port,
      _ => null,
    };
    final declaredDds = ports.dds is FixedPort
        ? (ports.dds as FixedPort).port
        : null;
    if (hostVmServicePort != null) {
      return flutterAttachArgv(
        deviceId: attachDeviceId,
        hostVmServicePort: hostVmServicePort,
        ddsPort: declaredDds,
      );
    }
    if (ports.okaOwnsHostVmServiceForward &&
        declaredDds == attachDdsPortWhenOkaOwnsHostForward) {
      return flutterAttachArgv(
        deviceId: attachDeviceId,
        ddsPort: attachDdsPortWhenOkaOwnsHostForward,
        okaOwnedForwardWithoutHostPort: true,
      );
    }
    return flutterAttachArgv(deviceId: attachDeviceId, ddsPort: declaredDds);
  }
}

/// Mirrors `flutterAttachMachineArgs` in `oka_android` (keep in sync).
List<String> flutterAttachArgv({
  required String deviceId,
  int? deviceVmServicePort,
  int? hostVmServicePort,
  int? ddsPort,
  bool okaOwnedForwardWithoutHostPort = false,
}) {
  final hostForward = hostVmServicePort != null && hostVmServicePort > 0
      ? hostVmServicePort
      : null;
  final effectiveDds = hostForward != null
      ? (ddsPort ?? attachDdsPortWhenOkaOwnsHostForward)
      : ddsPort;
  if (hostForward != null &&
      effectiveDds != null &&
      effectiveDds > 0 &&
      effectiveDds == hostForward) {
    throw ArgumentError.value(
      effectiveDds,
      'ddsPort',
      'must not equal hostVmServicePort ($hostForward) when oka owns the '
          'forward',
    );
  }
  if (okaOwnedForwardWithoutHostPort &&
      effectiveDds == attachDdsPortWhenOkaOwnsHostForward) {
    return [
      'attach',
      '--machine',
      '-d',
      deviceId,
      '--dds-port',
      '$attachDdsPortWhenOkaOwnsHostForward',
    ];
  }
  return [
    'attach',
    '--machine',
    '-d',
    deviceId,
    if (deviceVmServicePort != null && deviceVmServicePort > 0) ...[
      '--device-vmservice-port',
      '$deviceVmServicePort',
    ],
    if (hostForward != null) ...[
      '--host-vmservice-port',
      '$hostForward',
      if (effectiveDds != null) ...['--dds-port', '$effectiveDds'],
    ],
  ];
}
