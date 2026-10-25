import 'dart:io';

import 'package:oka_android/src/compilation/manifest_merge.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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

  const libraryManifestXml = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.lib">
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.INTERNET" />
    <application>
        <service android:name="com.example.lib.MetadataHolderService" />
        <activity android:name="com.example.app.MainActivity" android:exported="false" />
    </application>
</manifest>
''';

  Future<File> writeLibrary(String name, String xml) async {
    final file = File(p.join(tempDir.path, name));
    await file.writeAsString(xml);
    return file;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('oka_manifest_merge');
    appManifest = File(p.join(tempDir.path, 'AndroidManifest.xml'));
    await appManifest.writeAsString(appManifestXml);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('copies library services and permissions into the app manifest',
      () async {
    final library = await writeLibrary('lib_manifest.xml', libraryManifestXml);

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );

    expect(added, 2, reason: 'service + CAMERA permission; existing '
        'INTERNET and MainActivity are not re-added');
    final merged = appManifest.readAsStringSync();
    expect(merged, contains('com.example.lib.MetadataHolderService'));
    expect(merged, contains('android.permission.CAMERA'));
    // Exactly one INTERNET permission and one MainActivity survive.
    expect('android.permission.INTERNET'.allMatches(merged).length, 1);
    expect('com.example.app.MainActivity"'.allMatches(merged).length, 1);
  });

  test('is idempotent across repeated merges', () async {
    final library = await writeLibrary('lib_manifest.xml', libraryManifestXml);
    mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );
    final second = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );
    expect(second, 0);
  });

  test('skips tools:node=remove elements', () async {
    final library = await writeLibrary(
      'lib_manifest.xml',
      libraryManifestXml.replaceFirst(
        '<service android:name="com.example.lib.MetadataHolderService" />',
        '<service android:name="com.example.lib.Gone" '
        'tools:node="remove" xmlns:tools="http://schemas.android.com/apk/res/tools" />',
      ),
    );

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );

    expect(added, 1, reason: 'only the CAMERA permission merges');
    expect(appManifest.readAsStringSync(), isNot(contains('lib.Gone')));
  });

  test('merges nameless elements by attribute signature', () async {
    const feature = '<uses-feature android:glEsVersion="0x00030000" '
        'android:required="true" />';
    final library = await writeLibrary(
      'lib_manifest.xml',
      libraryManifestXml.replaceFirst('</manifest>', '$feature</manifest>'),
    );

    final first = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );
    final second = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );

    expect(first, 3, reason: 'CAMERA permission, service, and the feature');
    expect(second, 0, reason: 'same signature must not merge twice');
    expect(appManifest.readAsStringSync(), contains('glEsVersion'));
  });

  test('strips tools: attributes from copied elements', () async {
    final library = await writeLibrary(
      'lib_manifest.xml',
      '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/apk/res/tools"
    package="com.example.lib">
    <application>
        <service android:name="com.example.lib.CameraInit" tools:node="merge"
            tools:ignore="Instantiatable" />
    </application>
</manifest>
''',
    );

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );

    expect(added, 1);
    final merged = appManifest.readAsStringSync();
    expect(merged, contains('com.example.lib.CameraInit'));
    expect(merged, isNot(contains('tools:')), reason: 'the app manifest does '
        'not declare the tools namespace; copied tools: attributes render '
        'as unbound prefixes and fail aapt2 link');
  });

  test('substitutes the app application id into a library placeholder',
      () async {
    final library = await writeLibrary(
      'lib_manifest.xml',
      '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.lib">
    <uses-permission android:name="${r'${applicationId}'}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION" />
    <application>
        <receiver android:name="com.example.lib.Receiver" />
    </application>
</manifest>
''',
    );

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );

    expect(added, 2, reason: 'the permission is substituted and merges, '
        'together with the receiver');
    final merged = appManifest.readAsStringSync();
    expect(
      merged,
      contains('com.example.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'),
    );
    expect(merged, isNot(contains(r'${applicationId}')));
  });

  test('an app permission dedupes against the substituted library one',
      () async {
    await appManifest.writeAsString(appManifestXml.replaceFirst(
      '    <application android:label="App">',
      '    <uses-permission '
          'android:name="com.example.app.DYNAMIC_RECEIVER_PERMISSION" />\n'
          '    <application android:label="App">',
    ));
    final library = await writeLibrary(
      'lib_manifest.xml',
      '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.lib">
    <uses-permission android:name="${r'${applicationId}'}.DYNAMIC_RECEIVER_PERMISSION" />
    <application>
        <receiver android:name="com.example.lib.Receiver" />
    </application>
</manifest>
''',
    );

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );

    expect(added, 1, reason: 'only the receiver merges — the app already '
        'declares the substituted permission');
    final merged = appManifest.readAsStringSync();
    expect(
      'com.example.app.DYNAMIC_RECEIVER_PERMISSION'.allMatches(merged).length,
      1,
    );
  });

  test('skips elements with a placeholder the build cannot resolve',
      () async {
    final library = await writeLibrary(
      'lib_manifest.xml',
      '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.lib">
    <uses-permission android:name="${r'${firebaseCollectionId}'}.PERMISSION" />
    <application>
        <receiver android:name="com.example.lib.Receiver" />
    </application>
</manifest>
''',
    );

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );

    expect(added, 1, reason: 'the receiver merges; an unresolved placeholder '
        'cannot be substituted and would break at install time');
    final merged = appManifest.readAsStringSync();
    expect(merged, contains('com.example.lib.Receiver'));
    expect(merged, isNot(contains(r'${firebaseCollectionId}')));
  });

  test('without an application id the placeholder stays refused', () async {
    await appManifest.writeAsString(appManifestXml.replaceFirst(
      '    package="com.example.app"',
      '',
    ));
    final library = await writeLibrary(
      'lib_manifest.xml',
      '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.lib">
    <uses-permission android:name="${r'${applicationId}'}.DYNAMIC_RECEIVER_PERMISSION" />
    <application>
        <receiver android:name="com.example.lib.Receiver" />
    </application>
</manifest>
''',
    );

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
    );

    expect(added, 1, reason: 'the receiver merges; without an application id '
        'the placeholder cannot be resolved');
    expect(
      appManifest.readAsStringSync(),
      isNot(contains(r'${applicationId}')),
    );
  });

  test('an explicit application id overrides the manifest package', () async {
    final library = await writeLibrary(
      'lib_manifest.xml',
      '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.lib">
    <uses-permission android:name="${r'${applicationId}'}.DYNAMIC_RECEIVER_PERMISSION" />
</manifest>
''',
    );

    final added = mergeLibraryManifestsInto(
      appManifestPath: appManifest.path,
      libraryManifestPaths: [library.path],
      applicationId: 'com.example.flavor',
    );

    expect(added, 1);
    expect(
      appManifest.readAsStringSync(),
      contains('com.example.flavor.DYNAMIC_RECEIVER_PERMISSION'),
    );
  });

  test('throws on a malformed app manifest root', () async {
    await appManifest.writeAsString('<not-a-manifest />');
    final library = await writeLibrary('lib_manifest.xml', libraryManifestXml);

    expect(
      () => mergeLibraryManifestsInto(
        appManifestPath: appManifest.path,
        libraryManifestPaths: [library.path],
      ),
      throwsArgumentError,
    );
  });
}
