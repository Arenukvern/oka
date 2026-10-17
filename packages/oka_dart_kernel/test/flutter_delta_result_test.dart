import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';
import '../tool/flutter_delta.dart';
import '../tool/frontend_protocol.dart';

void main() {
  test(
    'terminal parsing keeps paths with spaces and requires final error count',
    () {
      final valid = parseFrontendResult(
        'result key\nkey\n+file:///x\nkey /path with spaces/output.dill 0\n',
      );
      expect(valid!.path, '/path with spaces/output.dill');
      expect(valid.errors, 0);
      expect(parseFrontendResult('result key\nkey\n'), isNull);
      expect(parseFrontendResult('result key\nkey /out.dill 1\n')!.errors, 1);
      expect(parseFrontendResult('result key\nwrong /out.dill 0\n'), isNull);
      expect(
        parseFrontendResult('result key\nkey /out.dill 0\nresult next\n'),
        isNull,
      );
    },
  );

  test(
    'real Flutter frontend accepts a valid library root without main',
    () async {
      final flutter = Platform.environment['FLUTTER_BIN'];
      if (flutter == null) {
        markTestSkipped('Set FLUTTER_BIN for real compiler coverage');
        return;
      }
      final directory = await Directory.systemTemp.createTemp(
        'oka valid library ',
      );
      try {
        final source = File('${directory.path}/unit.dart')
          ..writeAsStringSync('String label() => "valid";');
        final packages = File('${directory.path}/package_config.json')
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');
        final (sdk, frontend, patched) = flutterToolchainPaths(flutter);
        final artifact =
            await flutterFrontendDeltaCompiler(
              frontend,
              sdk,
              patched,
              packages.path,
            )(
              DeltaRequest(
                revision: 'valid',
                unit: 'valid',
                root: directory.path,
                patchedFiles: [source.path],
              ),
            );
        expect(artifact.bytes, greaterThan(0));
        await File(artifact.path).parent.delete(recursive: true);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'real Flutter frontend rejects invalid source even when dill exists',
    () async {
      final flutter = Platform.environment['FLUTTER_BIN'];
      if (flutter == null) {
        markTestSkipped('Set FLUTTER_BIN for the real frontend regression');
        return;
      }
      final directory = await Directory.systemTemp.createTemp(
        'oka-invalid-frontend',
      );
      try {
        final source = File('${directory.path}/unit.dart')
          ..writeAsStringSync('String label() => ;');
        final packages = File('${directory.path}/package_config.json')
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');
        final (sdk, frontend, patched) = flutterToolchainPaths(flutter);
        await expectLater(
          flutterFrontendDeltaCompiler(frontend, sdk, patched, packages.path)(
            DeltaRequest(
              revision: 'invalid',
              unit: 'invalid',
              root: directory.path,
              patchedFiles: [source.path],
            ),
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
