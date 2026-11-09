/// Publisher side of the S2 slot gate: `keys` mints an ed25519 channel
/// signer (seed + public anchor files); `sign` writes one signed
/// slot-update envelope through the SAME channel-signing surface the air
/// channel uses (`writeSlotUpdateEnvelope`, ADR-0037 G-AC5 identity).
///
/// Usage:
/// `dart run tool/s2_gate_publish.dart keys --keys-dir dir`
/// `dart run tool/s2_gate_publish.dart sign --seed-file f --dir d
///   --channel stable --family feature --revision r2
///   [--artifact relative-path --artifact-root dir]`
library;
import 'dart:io';

import 'package:oka_update/oka_update.dart';

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? '' : args[0];
  String option(String name) {
    final i = args.indexOf('--$name');
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : '';
  }

  switch (mode) {
    case 'keys':
      final keysDir = option('keys-dir');
      if (keysDir.isEmpty) return _usage();
      final signer = await ChannelSigner.generate();
      Directory(keysDir).createSync(recursive: true);
      final seed = File('$keysDir/seed.hex');
      seed.writeAsStringSync('${await signer.keySeedHex()}\n');
      Process.runSync('chmod', ['600', seed.path]);
      File('$keysDir/public.hex')
          .writeAsStringSync('${signer.publicKeyHex}\n');
      stdout.writeln('keys: keyId=${signer.keyId} '
          'public=${'$keysDir/public.hex'}');
    case 'sign':
      final seedFile = option('seed-file');
      final dir = option('dir');
      if (seedFile.isEmpty || dir.isEmpty) return _usage();
      final signer = ChannelSigner.fromSeedHex(
          File(seedFile).readAsStringSync().trim());
      final artifactPath = option('artifact');
      final artifactRoot = option('artifact-root');
      UnitArtifact? artifact;
      if (artifactPath.isNotEmpty) {
        final absolute =
            '$artifactRoot/$artifactPath'.replaceAll('//', '/');
        artifact = UnitArtifact(
          file: artifactPath,
          sha256: sha256File(absolute),
          bytes: File(absolute).lengthSync(),
        );
      }
      final envelope = await writeSlotUpdateEnvelope(
        directory: dir,
        channel: option('channel').isEmpty ? 'stable' : option('channel'),
        family: option('family').isEmpty ? 'feature' : option('family'),
        revision: option('revision').isEmpty ? 'r2' : option('revision'),
        signer: await signer,
        artifact: artifact,
        fileName: option('filename').isEmpty ? null : option('filename'),
      );
      stdout.writeln('envelope: ${envelope.path}');
    default:
      _usage();
  }
}

void _usage() {
  stderr.writeln('usage: s2_gate_publish.dart keys --keys-dir <dir>\n'
      '       s2_gate_publish.dart sign --seed-file <f> --dir <d> '
      '[--channel c] [--family f] [--revision r] '
      '[--artifact rel --artifact-root dir]');
  exitCode = 64;
}
