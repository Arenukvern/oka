import 'dart:io';

import 'package:test/test.dart';

import '../tool/contracts/check_architecture.dart';

void main() {
  test('current package boundaries hold recursively', () {
    final report = inspectArchitecture(Directory.current);
    expect(report['violations'], isEmpty);
  });

  test(
    'nested dependency violations fail but cohesive large files only warn',
    () async {
      final root = await Directory.systemTemp.createTemp('oka-architecture-');
      addTearDown(() => root.delete(recursive: true));
      final bad = File('${root.path}/packages/oka_core/lib/src/deep/bad.dart');
      await bad.parent.create(recursive: true);
      await bad.writeAsString(
        "import 'package:oka_android/oka_android.dart';\n",
      );
      final large = File('${root.path}/packages/oka_core/lib/src/models.dart');
      await large.writeAsString(
        List.filled(805, '// coherent model fixture').join('\n'),
      );
      var report = inspectArchitecture(root);
      expect(report['ok'], isFalse);
      expect(report['violations'], hasLength(1));
      expect(report['hotspots'], hasLength(1));
      await bad.writeAsString("import 'dart:io';\n");
      report = inspectArchitecture(root);
      expect(report['ok'], isTrue);
      expect(report['hotspots'], hasLength(1));
    },
  );

  test('application to presentation dependency is rejected', () async {
    final root = await Directory.systemTemp.createTemp('oka-layer-');
    addTearDown(() => root.delete(recursive: true));
    final file = File(
      '${root.path}/packages/oka/lib/src/cache/inspection.dart',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString("import '../cli/cache_command.dart';\n");
    expect(inspectArchitecture(root)['violations'], hasLength(1));
  });

  test('relative cross-package imports obey the same boundaries', () async {
    final root = await Directory.systemTemp.createTemp('oka-relative-layer-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/packages/oka_core/lib/src/bad.dart');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      "import '../../../oka_android/lib/oka_android.dart';\n",
    );
    expect(inspectArchitecture(root)['violations'], hasLength(1));
  });
}
