import 'package:oka_dart_kernel/src/gate/supervisor_session_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('parseSupervisorDrainAck', () {
    final ack = parseSupervisorDrainAck(
      'oka_dev_supervisor_drain_ack nonce=abc settled=true verified=true survivors=',
    );
    expect(ack, isNotNull);
    expect(ack!.nonce, 'abc');
    expect(ack.settled, isTrue);
    expect(ack.verified, isTrue);
    expect(ack.survivors, isEmpty);
  });

  test('parseFixtureEscapedReport', () {
    final esc = parseFixtureEscapedReport(
      'oka_dev_fixture_escaped_pid=4242 token=fixture-setsid-4242',
    );
    expect(esc?.pid, 4242);
    expect(esc?.token, 'fixture-setsid-4242');
  });
}
