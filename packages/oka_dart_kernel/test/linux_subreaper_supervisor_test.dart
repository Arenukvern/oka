import 'package:oka_dart_kernel/src/package_root.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('production supervisor lives under tool/', () async {
    final kernelRoot = await resolveOkaDartKernelRoot();
    expect(
      p.join(kernelRoot, 'tool', 'linux_subreaper_supervisor.dart'),
      isNotEmpty,
    );
  });
}
