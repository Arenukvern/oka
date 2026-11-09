import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

import 'support/fake_daemon_transport.dart';

void main() {
  test('app.stop before app.started fails fast without waiting full timeout', () async {
    final t = FakeDaemonTransport();
    final adapter = FlutterDaemonAdapter(transport: t);
    t.emitEvent('daemon.connected', {'version': '0.6.1'});
    t.emitEvent('app.start', {'appId': 'com.example.app'});
    t.emitEvent('app.stop', {'appId': 'com.example.app'});

    final sw = Stopwatch()..start();
    final failure = await adapter.waitForAppStarted(
      timeout: const Duration(seconds: 30),
    );
    sw.stop();

    expect(failure, AttachHandshakeFailure.appStopBeforeStarted);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    adapter.dispose();
  });
}
