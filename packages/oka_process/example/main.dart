import 'package:oka_process/oka_process.dart';

/// Lists backend wire names; launch/stop are stubbed until P0/P1 land.
void main() {
  for (final kind in ProcessSessionBackendKind.values) {
    // ignore: avoid_print
    print('backend: ${kind.wireName}');
  }
  final backend = PosixPerlProcessSessionBackend();
  // ignore: avoid_print
  print('selected: ${backend.kind.wireName} (launch not implemented yet)');
}
