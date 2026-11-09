/// Declared host-side ports for attach and adb forwarding.
library;

import 'package:meta/meta.dart';

import 'port_choice.dart';
import 'spec_violation.dart';

/// Ports for VM service, DDS, adb forward, and the dev control server.
@immutable
final class PortPlan with TypedSpec {
  const PortPlan({
    required this.hostVmService,
    required this.dds,
    required this.adbForward,
    required this.control,
  });

  final PortChoice hostVmService;
  final PortChoice dds;
  final PortChoice adbForward;
  final PortChoice control;

  @override
  List<String> validate() => [
    ..._validateChoice(hostVmService, 'ports.hostVmService'),
    ..._validateChoice(dds, 'ports.dds'),
    ..._validateChoice(adbForward, 'ports.adbForward', allowDelegated: true),
    ..._validateChoice(control, 'ports.control'),
    ..._validateHostDdsConflict(),
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
      if (host == ddsPort) {
        final message =
            'ports: hostVmService and dds must not use the same '
            'fixed port ($host)';
        return [message];
      }
    }
    return const [];
  }
}
