import 'dart:io';

import 'package:path/path.dart' as p;

import '../build/flutter_assemble.dart' show readFlutterEngineRevision;

final class FlutterSdkSnapshot {
  const FlutterSdkSnapshot({
    required this.binaryPath,
    required this.binaryExists,
    required this.engineRevision,
  });

  final String binaryPath;
  final bool binaryExists;
  final String engineRevision;
}

// The interface keeps preflight independent from host SDK I/O.
// ignore: one_member_abstracts
abstract interface class FlutterSdkProbe {
  Future<FlutterSdkSnapshot> inspect(String sdkPath);
}

final class HostFlutterSdkProbe implements FlutterSdkProbe {
  const HostFlutterSdkProbe();

  @override
  Future<FlutterSdkSnapshot> inspect(String sdkPath) async {
    final binaryPath = p.join(
      sdkPath,
      'bin',
      'flutter${Platform.isWindows ? '.bat' : ''}',
    );
    final binary = File(binaryPath);
    final versionFile = File(
      p.join(sdkPath, 'bin', 'internal', 'engine.version'),
    );
    String revision = '';
    if (versionFile.existsSync()) {
      revision = versionFile.readAsStringSync().trim();
    } else if (binary.existsSync()) {
      revision = await readFlutterEngineRevision(
            runProcess: (_, args) => Process.run(binaryPath, args),
          ) ??
          '';
    }
    return FlutterSdkSnapshot(
      binaryPath: binaryPath,
      binaryExists: binary.existsSync(),
      engineRevision: revision,
    );
  }
}
