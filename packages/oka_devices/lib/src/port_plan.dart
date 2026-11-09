/// Declared host-side ports for attach and adb forwarding.
library;

import 'package:meta/meta.dart';

import 'port_choice.dart';
import 'spec_violation.dart';

/// `--dds-port` when oka already created `adb forward tcp:<host> …` (Flutter
/// 3.47.5+); must match `attachDdsPortWhenOkaOwnsHostForward` in
/// `daemon_adapter.dart`.
const attachDdsPortWhenOkaOwnsHostForward = 0;

/// Ports for VM service, DDS, adb forward, and the dev control server.
@immutable
final class PortPlan with TypedSpec {
  const PortPlan({
    required this.hostVmService,
    required this.dds,
    required this.adbForward,
    required this.control,
  });

  /// Default attach ports when oka owns the host VM-service forward.
  factory PortPlan.okaOwnsHostForward() => const PortPlan(
    hostVmService: OkaAllocated(),
    dds: FixedPort(attachDdsPortWhenOkaOwnsHostForward),
    adbForward: Delegated(),
    control: OkaAllocated(),
  );

  final PortChoice hostVmService;
  final PortChoice dds;
  final PortChoice adbForward;
  final PortChoice control;

  /// oka will allocate or bind the loopback forward (not delegated tcp:0 only).
  bool get okaOwnsHostVmServiceForward => switch (hostVmService) {
    OkaAllocated() => true,
    FixedPort(:final port) => port > 0,
    Delegated() => false,
  };

  @override
  List<String> validate() => [
    ..._validateChoice(hostVmService, 'ports.hostVmService'),
    ..._validateChoice(dds, 'ports.dds'),
    ..._validateChoice(adbForward, 'ports.adbForward', allowDelegated: true),
    ..._validateChoice(control, 'ports.control'),
    ..._validateHostDdsConflict(),
    ..._validateOkaOwnedForwardDds(),
  ];

  List<String> _validateChoice(
    PortChoice choice,
    String field, {
    bool allowDelegated = false,
  }) {
    final problems = <String>[];
    if (choice is Delegated && !allowDelegated) {
      problems.add('$field: Delegated is only valid for ports.adbForward');
    }
    problems.addAll(switch (choice) {
      FixedPort(:final port) => FixedPort(port).validate(field: field),
      OkaAllocated() || Delegated() => const <String>[],
    });
    return problems;
  }

  List<String> _validateHostDdsConflict() {
    if (hostVmService is FixedPort && dds is FixedPort) {
      final host = (hostVmService as FixedPort).port;
      final ddsPort = (dds as FixedPort).port;
      if (host > 0 && ddsPort > 0 && host == ddsPort) {
        final message =
            'ports: hostVmService and dds must not use the same '
            'fixed port ($host)';
        return [message];
      }
    }
    return const [];
  }

  List<String> _validateOkaOwnedForwardDds() {
    if (!okaOwnsHostVmServiceForward) {
      return const [];
    }
    if (dds is! FixedPort ||
        (dds as FixedPort).port != attachDdsPortWhenOkaOwnsHostForward) {
      const message =
          'ports: when oka owns the host VM-service forward, '
          'dds must be FixedPort(0)';
      return [message];
    }
    return const [];
  }
}
