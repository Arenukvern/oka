import 'package:oka_android/src/build/gradle_dep_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseGradleDependencies', () {
    test('parses kotlin dsl implementation()', () {
      const src = '''
dependencies {
    implementation("androidx.core:core:1.17.0")
    implementation("androidx.browser:browser:1.9.0")
    api("org.jetbrains.kotlin:kotlin-stdlib:2.0.21")
}
''';
      final deps = parseGradleDependencies(src);
      expect(deps.map((d) => d.coordinate), containsAll([
        'androidx.core:core:1.17.0',
        'androidx.browser:browser:1.9.0',
        'org.jetbrains.kotlin:kotlin-stdlib:2.0.21',
      ]));
    });

    test('parses groovy single quotes', () {
      const src = "implementation 'androidx.annotation:annotation:1.9.1'";
      final deps = parseGradleDependencies(src);
      expect(deps.single.coordinate, 'androidx.annotation:annotation:1.9.1');
    });

    test('skips version variables', () {
      const src = r'implementation("org.jetbrains.kotlin:kotlin-stdlib-jdk7:$kotlinVersion")';
      expect(parseGradleDependencies(src), isEmpty);
    });
  });

  group('parseMavenRepositoryUrls', () {
    test('extracts uri repositories', () {
      const src = '''
maven {
    url = uri("https://artifactory-external.vkpartner.ru/artifactory/maven")
}
''';
      final urls = parseMavenRepositoryUrls(src);
      expect(
        urls,
        contains('https://artifactory-external.vkpartner.ru/artifactory/maven'),
      );
    });
  });
}
