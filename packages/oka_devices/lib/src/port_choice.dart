/// How a host-side port is chosen for dev tooling.
library;

/// Port selection strategy.
sealed class PortChoice {
  const PortChoice();
}

/// A fixed, caller-declared port.
final class FixedPort extends PortChoice {
  const FixedPort(this.port);

  final int port;

  List<String> validate({required String field}) {
    final problems = <String>[];
    if (port < 0 || port > 65535) {
      problems.add('$field: port must be 0..65535 (got $port)');
    }
    return problems;
  }
}

/// oka allocates and holds the port before attach (no flutter flag in [plan]).
final class OkaAllocated extends PortChoice {
  const OkaAllocated();
}

/// `adb forward tcp:0` — delegated local port ([PortPlan.adbForward] only).
final class Delegated extends PortChoice {
  const Delegated();
}
