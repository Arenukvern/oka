import 'package:oka_process/oka_process.dart';

Future<void> main() async {
  for (final kind in ProcessSessionBackendKind.values) {
    // ignore: avoid_print
    print('backend: ${kind.wireName}');
  }
  final backend = PosixPerlProcessSessionBackend();
  final handle = await backend.launch(
    const OwnedProcessLaunchSpec(executable: 'sleep', arguments: ['2']),
  );
  // ignore: avoid_print
  print('launched leader pid=${handle.leaderIdentity.pid}');
  final receipt = await backend.stop(handle);
  // ignore: avoid_print
  print('stop settled=${receipt.isSettled}');
}
