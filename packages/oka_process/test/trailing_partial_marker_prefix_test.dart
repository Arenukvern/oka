@TestOn('vm')
library;

import 'dart:convert';

import 'package:oka_process/oka_process.dart';
import 'package:test/test.dart';

void main() {
  const marker = 'marker';
  final failureBytes = utf8.encode('$marker:error:');

  test(
    'trailingPartialMarkerPrefixBytes matches only failure-marker prefix',
    () {
      expect(trailingPartialMarkerPrefixBytes(<int>[], failureBytes), 0);
      expect(
        trailingPartialMarkerPrefixBytes(
          utf8.encode('log line\nerror:'),
          failureBytes,
        ),
        0,
        reason: 'internal marker substring is not a true prefix hold',
      );
      expect(
        trailingPartialMarkerPrefixBytes(
          utf8.encode('partial marker:e'),
          failureBytes,
        ),
        utf8.encode('marker:e').length,
      );
      expect(
        trailingPartialMarkerPrefixBytes(failureBytes, failureBytes),
        failureBytes.length,
        reason: 'full failure marker suffix must be held across chunks',
      );
    },
  );

  test(
    'post-startup captureStatus ingests failure marker split before payload',
    () {
      expect(
        startupFailureFromPostStartupStatusChunks(marker, [
          failureBytes,
          utf8.encode('exec:x\n'),
        ]),
        'exec:x',
      );
    },
  );
}
