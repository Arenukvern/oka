import 'dart:io';

import 'package:oka_process/oka_process.dart';

Future<void> main() async {
  final backend = PosixPerlProcessSessionBackend();
  final handle = await backend.launch(
    const OwnedProcessLaunchSpec(executable: 'sleep', arguments: ['3600']),
  );
  // ignore: avoid_print
  print('handle identity: ${handle.leaderIdentity}');
  final before = await Process.run('kill', ['-0', '${handle.leaderIdentity.pid}']);
  // ignore: avoid_print
  print('leader alive before stop: ${before.exitCode == 0}');
  final receipt = await backend.stop(handle);
  final after = await Process.run('kill', ['-0', '${handle.leaderIdentity.pid}']);
  // ignore: avoid_print
  print('leader alive after stop: ${after.exitCode == 0}');
  // ignore: avoid_print
  // ignore: avoid_print
  print(
    'settlement=${receipt.settlement.runtimeType} '
    'isSettled=${receipt.isSettled} '
    'reason=${receipt.settlement is SettlementUnsettled ? (receipt.settlement as SettlementUnsettled).reason : "n/a"}',
  );
}
