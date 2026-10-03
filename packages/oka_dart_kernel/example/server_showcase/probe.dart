/// Probe loop for the handoff demo: connect, read the label, print
/// `OK <label>` or `REFUSED`. Dart-native so the demo runs in containers
/// without curl.
import 'dart:io';

Future<void> main(List<String> args) async {
  final port = int.parse(args[0]);
  final iterations = args.length > 1 ? int.parse(args[1]) : 60;
  for (var i = 0; i < iterations; i++) {
    try {
      final socket = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 500));
      final label = await socket
          .map((c) => String.fromCharCodes(c))
          .join();
      // ignore: avoid_print
      print('OK ${label.trim()}');
      await socket.close();
    } catch (_) {
      // ignore: avoid_print
      print('REFUSED');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
