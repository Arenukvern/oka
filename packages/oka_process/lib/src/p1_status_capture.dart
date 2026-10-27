import 'dart:convert';

import 'package:meta/meta.dart';

/// Longest suffix of [bytes] that is a prefix of [failureBytes].
@visibleForTesting
int trailingPartialMarkerPrefixBytes(List<int> bytes, List<int> failureBytes) {
  var partialLen = 0;
  for (
    var tail = 1;
    tail <= failureBytes.length && tail <= bytes.length;
    tail++
  ) {
    var matches = true;
    for (var j = 0; j < tail; j++) {
      if (failureBytes[j] != bytes[bytes.length - tail + j]) {
        matches = false;
        break;
      }
    }
    if (matches) partialLen = tail;
  }
  return partialLen;
}

/// Post-startup hold/flush for split `<marker>:error:` lines.
@visibleForTesting
String? startupFailureFromPostStartupStatusChunks(
  String marker,
  List<List<int>> chunks,
) {
  final failureBytes = utf8.encode('$marker:error:');
  final postStartupErrBytes = <int>[];
  for (final chunk in chunks) {
    postStartupErrBytes.addAll(chunk);
    final failed = _byteSequenceIndex(postStartupErrBytes, failureBytes);
    if (failed >= 0) {
      final end = postStartupErrBytes.indexOf(10, failed);
      if (end >= 0) {
        return utf8.decode(
          postStartupErrBytes.sublist(failed + failureBytes.length, end),
          allowMalformed: true,
        );
      }
    }
    final partialLen = trailingPartialMarkerPrefixBytes(
      postStartupErrBytes,
      failureBytes,
    );
    final flushUpTo = postStartupErrBytes.length - partialLen;
    if (flushUpTo > 0) {
      postStartupErrBytes.removeRange(0, flushUpTo);
    }
  }
  return null;
}

int _byteSequenceIndex(List<int> bytes, List<int> needle) {
  outer:
  for (var i = 0; i <= bytes.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
