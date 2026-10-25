import 'dart:io';

import 'package:oka_android/src/compilation/manifest_merge.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Regression coverage for the multi-library manifest deduplication fix.
///
/// Gradle's manifest merger folds every AAR's declarations into the app
/// manifest, and oka has to do the same for aapt2. When two libraries declare
/// the same permission or the same provider, exactly one declaration may end up
/// in the app manifest, and a declaration the app owns must never be replaced
/// by a library one.
void main() {
  late Directory tempDir;
  late File appManifest;

  const appManifestXml = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.app">
    <uses-permission android:name="android.permission.INTERNET" />
    <application android:label="App">
        <activity android:name="com.example.app.MainActivity" />
    </application>
</manifest>
''';

  const libraryAXml = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.libA">
    <uses-permission android:name="android.permission.CAMERA" />
    <application>
        <provider android:name="com.example.shared.Provider"
            android:authorities="com.example.app.provider" />
    </application>
</manifest>
''';

  const libraryBXml = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.libB">
    <uses-permission android:name="android.permission.CAMERA" />
    <application>
        <provider android:name="com.example.shared.Provider"
            android:authorities="com.example.app.provider" />
    </application>
</manifest>
''';

  Future<File> writeLibrary(String name, String xml) async {
    final file = File(p.join(tempDir.path, name));
    await file.writeAsString(xml);
    return file;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('oka_manifest_multi');
    appManifest = File(p.join(tempDir.path, 'AndroidManifest.xml'));
    await appManifest.writeAsString(appManifestXml);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('two libraries declaring the same permission and provider merge once',
      () async {
    final libraryA = await writeLibrary('lib_a.xml', libraryAXml);
    final libraryB = await writeLibrary('lib_b.xml', libraryBXml);

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [libraryA.path, libraryB.path],
    );

    expect(added, 2,
        reason: 'the shared CAMERA permission and the shared provider are '
            'each added once, not once per library');
    final merged = appManifest.readAsStringSync();
    expect('android.permission.CAMERA'.allMatches(merged).length, 1);
    expect(
      'android:name="com.example.shared.Provider"'.allMatches(merged).length,
      1,
    );
    // The library provider keeps its own attributes.
    expect(merged, contains('android:authorities="com.example.app.provider"'));
    // The app's own permission is untouched and not duplicated.
    expect('android.permission.INTERNET'.allMatches(merged).length, 1);
  });

  test('app-owned declarations win over the libraries', () async {
    await appManifest.writeAsString(appManifestXml.replaceFirst(
      '    <application android:label="App">',
      '    <uses-permission android:name="android.permission.CAMERA" />\n'
          '    <application android:label="App">',
    ).replaceFirst(
      '        <activity android:name="com.example.app.MainActivity" />',
      '        <activity android:name="com.example.app.MainActivity" />\n'
          '        <provider android:name="com.example.shared.Provider"\n'
          '            android:authorities="com.example.app.owned" />',
    ));
    final libraryA = await writeLibrary('lib_a.xml', libraryAXml);
    final libraryB = await writeLibrary('lib_b.xml', libraryBXml);

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [libraryA.path, libraryB.path],
    );

    expect(added, 0,
        reason: 'the app already declares both the permission and the '
            'provider, so nothing may be merged');
    final merged = appManifest.readAsStringSync();
    expect('android.permission.CAMERA'.allMatches(merged).length, 1);
    expect(
      'android:name="com.example.shared.Provider"'.allMatches(merged).length,
      1,
    );
    // The app's own provider attributes survive: the library declaration did
    // not overwrite them.
    expect(merged, contains('android:authorities="com.example.app.owned"'));
    expect(merged, isNot(contains('com.example.app.provider"')));
  });

  test('a second merge with the same libraries adds nothing and keeps bytes',
      () async {
    final libraryA = await writeLibrary('lib_a.xml', libraryAXml);
    final libraryB = await writeLibrary('lib_b.xml', libraryBXml);
    final libraryPaths = [libraryA.path, libraryB.path];

    final first = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: libraryPaths,
    );
    expect(first, 2);
    final bytesAfterFirst = appManifest.readAsBytesSync();

    final second = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: libraryPaths,
    );

    expect(second, 0, reason: 'the merged declarations are already present');
    expect(appManifest.readAsBytesSync(), orderedEquals(bytesAfterFirst),
        reason: 'a no-op merge must not rewrite the manifest');
    final merged = appManifest.readAsStringSync();
    expect('android.permission.CAMERA'.allMatches(merged).length, 1);
    expect(
      'android:name="com.example.shared.Provider"'.allMatches(merged).length,
      1,
    );
  });
}
