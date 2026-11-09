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

  /// adb serial for `flutter attach -d`.
  String get attachDeviceId => device.adbSerial;

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

  /// Flutter `attach` argv: machine attach prefix plus declared port flags.
  ///
  /// The attach prefix matches `flutterAttachMachineArgs` in
  /// `oka_android` (`attach`, `--machine`, `-d`, device id). Port flags
  /// follow only for fixed [PortPlan.hostVmService] / [PortPlan.dds]
  /// choices ([OkaAllocated] omits a flag until R4 binds).
  List<String> plan() => [
    'attach',
    '--machine',
    '-d',
    attachDeviceId,
    ..._flutterPortFlags(ports.hostVmService, '--host-vmservice-port'),
    ..._flutterPortFlags(ports.dds, '--dds-port'),
  ];
}

List<String> _flutterPortFlags(PortChoice choice, String flag) =>
    switch (choice) {
      FixedPort(:final port) => ['$flag=$port'],
      OkaAllocated() || Delegated() => const [],
    };
