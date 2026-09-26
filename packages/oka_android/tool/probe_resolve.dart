import 'package:oka_android/oka_android.dart';

Future<void> main() async {
  final cache = DependencyCache();
  final jars = await cache.resolveFlutterAndroidX();
  for (final jar in jars) {
    print('${jar.coordinate.groupId}:${jar.coordinate.artifactId}:${jar.coordinate.version} -> ${jar.jarPath}');
  }
}
