import 'dart:async';

import 'package:oka_android/oka_android.dart';

/// Waits until [adapter] has delivered a daemon event named [eventName].
Future<DaemonEvent> waitForDaemonEvent(
  FlutterDaemonAdapter adapter,
  String eventName, {
  Duration timeout = const Duration(seconds: 2),
}) =>
    adapter.events
        .firstWhere((event) => event.event == eventName)
        .timeout(timeout);
