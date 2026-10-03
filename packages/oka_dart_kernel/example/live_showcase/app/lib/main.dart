import 'dart:async';

import 'package:showcase_app/units/feature.dart';

final String bootStamp = DateTime.now().microsecondsSinceEpoch.toString();

String status() => 'feature=${feature()} boot=$bootStamp';

void main() {
  // ignore: avoid_print
  print('app: ${status()}');
  // Keep the isolate (and its VM service) alive so a patch can land live;
  // re-print so the patched value shows up in the app's own output.
  var tick = 0;
  Timer.periodic(const Duration(seconds: 2), (_) {
    // ignore: avoid_print
    print('app [tick ${tick++}]: ${status()}');
  });
}
