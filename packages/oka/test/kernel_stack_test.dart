import 'dart:io';

import 'package:oka/src/cli/kernel_stack.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _runner = 'packages/oka_dart_kernel/tool/oka_run_dev.dart';

void main() {
  test('kernelStackRootForScript walks past outer work/oka to inner repo', () async {
    final tmp = await Directory.systemTemp.createTemp('oka_kernel_root');
    addTearDown(() => tmp.delete(recursive: true));
    final inner = Directory(p.join(tmp.path, 'work', 'oka', 'oka'));
    await inner.create(recursive: true);
    await File(p.join(inner.path, _runner)).create(recursive: true);
    final script = File(p.join(inner.path, 'packages', 'oka', 'bin', 'oka.dart'));
    await script.create(recursive: true);

    final root = kernelStackRootForScript(script.path, _runner);
    expect(root, p.normalize(inner.path));
  });

  test('kernelStackRootForScript finds runner in differently named checkout', () async {
    final tmp = await Directory.systemTemp.createTemp('oka_kernel_rename');
    addTearDown(() => tmp.delete(recursive: true));
    await File(p.join(tmp.path, _runner)).create(recursive: true);
    final script =
        File(p.join(tmp.path, 'vendor', 'fork', 'packages', 'oka', 'bin', 'oka.dart'));
    await script.create(recursive: true);
    expect(
      kernelStackRootForScript(script.path, _runner),
      p.normalize(tmp.path),
    );
  });

  test('OKA_KERNEL_ROOT overrides walk when runner exists', () async {
    final tmp = await Directory.systemTemp.createTemp('oka_kernel_env');
    addTearDown(() => tmp.delete(recursive: true));
    await File(p.join(tmp.path, _runner)).create(recursive: true);
    final script = p.join(tmp.path, 'packages', 'oka', 'bin', 'oka.dart');
    await File(script).create(recursive: true);

    expect(
      kernelStackRootForScript(
        script,
        _runner,
        environment: {'OKA_KERNEL_ROOT': p.join(tmp.path, 'nowhere')},
      ),
      p.normalize(tmp.path),
      reason: 'missing runner under explicit root falls through to walk',
    );

    expect(
      kernelStackRootForScript(
        script,
        _runner,
        environment: {'OKA_KERNEL_ROOT': tmp.path},
      ),
      p.normalize(tmp.path),
    );
  });
}
