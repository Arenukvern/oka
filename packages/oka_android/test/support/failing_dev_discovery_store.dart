import 'dart:io';

import 'package:oka_android/src/dev/dev_discovery_store.dart';

/// Succeeds until [writeVmUri], which fails after the forward step artifacts exist.
final class FailingWriteVmUriDiscoveryStore implements DevDiscoveryStore {
  @override
  String vmUriPath(String projectPath) => '$projectPath/vm.uri';

  @override
  String runnerSessionPath(String projectPath) => '$projectPath/runner-session.json';

  @override
  Future<void> writeVmUri(String projectPath, String uri) =>
      Future<void>.error(
        const FileSystemException('simulated vm.uri write failure'),
      );

  @override
  Future<void> clearVmUri(String projectPath) => Future<void>.value();

  @override
  Future<void> writeRunnerSession(
    String projectPath, {
    required String vmServiceUri,
    required int controlPort,
    required String deviceId,
    int? processPid,
    DateTime? startedAt,
  }) async {}

  @override
  Future<void> clearRunnerSession(String projectPath) async {}

  @override
  DevSessionDiscoveryRecord? readRunnerSession(String projectPath) => null;
}
