// Machine-readable stderr lines between the dedicated subreaper supervisor
/// and [OwnedDevSession] (not host-global process guessing).

final class SupervisorDrainAck {
  const SupervisorDrainAck({
    required this.nonce,
    required this.settled,
    required this.verified,
    required this.survivors,
  });

  final String nonce;
  final bool settled;
  final bool verified;
  final List<int> survivors;
}

final class FixtureEscapedReport {
  const FixtureEscapedReport({required this.pid, required this.token});

  final int pid;
  final String token;
}

SupervisorDrainAck? parseSupervisorDrainAck(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('oka_dev_supervisor_drain_ack ')) return null;
  final parts = trimmed.substring('oka_dev_supervisor_drain_ack '.length);
  String? nonce;
  var settled = false;
  var verified = false;
  final survivors = <int>[];
  for (final segment in parts.split(RegExp(r'\s+'))) {
    final kv = segment.split('=');
    if (kv.length != 2) continue;
    switch (kv[0]) {
      case 'nonce':
        nonce = kv[1];
      case 'settled':
        settled = kv[1] == 'true';
      case 'verified':
        verified = kv[1] == 'true';
      case 'survivors':
        if (kv[1].isNotEmpty) {
          for (final p in kv[1].split(',')) {
            final id = int.tryParse(p);
            if (id != null) survivors.add(id);
          }
        }
    }
  }
  if (nonce == null || nonce.isEmpty) return null;
  return SupervisorDrainAck(
    nonce: nonce,
    settled: settled,
    verified: verified,
    survivors: survivors,
  );
}

FixtureEscapedReport? parseFixtureEscapedReport(String line) {
  final m = RegExp(
    r'^oka_dev_fixture_escaped_pid=(\d+) token=(\S+)$',
  ).firstMatch(line.trim());
  if (m == null) return null;
  return FixtureEscapedReport(
    pid: int.parse(m.group(1)!),
    token: m.group(2)!,
  );
}
