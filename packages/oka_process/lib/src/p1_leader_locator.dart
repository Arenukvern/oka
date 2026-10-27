import 'dart:io';
import 'dart:isolate';

/// Resolves the p1 Perl leader (`OWNED_SESSION_P1_LEADER` or package `tool/`).
String resolveOwnedSessionP1LeaderPath() {
  final fromEnv = Platform.environment['OWNED_SESSION_P1_LEADER'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }
  final entry = Isolate.resolvePackageUri(
    Uri.parse('package:oka_process/oka_process.dart'),
  );
  if (entry == null) {
    throw StateError('oka_process package URI not resolved');
  }
  final packageRoot = File.fromUri(entry).parent.parent;
  return '${packageRoot.path}/tool/owned_session_p1_leader.pl';
}

String? resolveSystemPerlPath() {
  for (final path in const ['/usr/bin/perl', '/bin/perl']) {
    if (File(path).existsSync()) return path;
  }
  return null;
}
