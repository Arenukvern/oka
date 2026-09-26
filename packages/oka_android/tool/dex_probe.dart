import 'package:oka_android/src/compilation/bytecode_compilation.dart';

/// Probes the runtime-jar filter with the exact cached jar paths.
Future<void> main() async {
  const jars = [
    '/Users/antonio/.oka/cache/maven/androidx/concurrent/concurrent-futures/1.1.0/concurrent-futures-1.1.0.jar',
    '/Users/antonio/.oka/cache/maven/androidx/concurrent/concurrent-futures/1.0.0/concurrent-futures-1.0.0.jar',
    '/Users/antonio/.oka/cache/maven/androidx/concurrent/concurrent-futures-ktx/1.0.0/concurrent-futures-ktx-1.0.0.jar',
  ];
  final out = filterRuntimeJars(jars);
  print('kept ${out.length} of ${jars.length}:');
  for (final j in out) {
    print('  $j');
  }
}
