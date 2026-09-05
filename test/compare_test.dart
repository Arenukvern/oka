import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _badgingA = '''
package: name='dev.xsoulspace.lastanswer' versionCode='51' versionName='3.22.0'
sdkVersion:'23'
targetSdkVersion:'36'
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.POST_NOTIFICATIONS'
application-label: 'Last Answer'
launchable-activity: name='dev.xsoulspace.lastanswer.MainActivity' label='Last Answer'
''';

const _badgingB = '''
package: name='dev.xsoulspace.lastanswer' versionCode='51' versionName='3.22.0'
sdkVersion:'23'
targetSdkVersion:'36'
uses-permission: name='android.permission.INTERNET'
application-label: 'Last Answer'
launchable-activity: name='dev.xsoulspace.lastanswer.MainActivity' label='Last Answer'
''';

File _writeZip(String path, Map<String, List<int>> entries) {
  final archive = Archive();
  for (final e in entries.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(ZipEncoder().encode(archive)!);
  return file;
}

void main() {
  group('parseBadging', () {
    test('extracts package, versions, permissions, launchable activity', () {
      final info = parseBadging(_badgingA);
      expect(info.packageName, 'dev.xsoulspace.lastanswer');
      expect(info.versionCode, '51');
      expect(info.versionName, '3.22.0');
      expect(info.minSdkVersion, '23');
      expect(info.targetSdkVersion, '36');
      expect(info.usesPermissions, [
        'android.permission.INTERNET',
        'android.permission.POST_NOTIFICATIONS',
      ]);
      expect(info.launchableActivity, 'dev.xsoulspace.lastanswer.MainActivity');
      expect(info.allLines, isNotEmpty);
    });
  });

  group('compareZipEntries', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('oka-compare-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('identical zip contents produce an empty diff', () {
      final a = _writeZip(p.join(tmp.path, 'a.apk'), {
        'classes.dex': [1, 2, 3],
        'res/values.xml': [4, 5],
      });
      final b = _writeZip(p.join(tmp.path, 'b.apk'), {
        'classes.dex': [1, 2, 3],
        'res/values.xml': [4, 5],
      });
      final diff = compareZipEntries(a.path, b.path);
      expect(diff.isEmpty, isTrue);
    });

    test('detects entries only in one artifact and changed content', () {
      final a = _writeZip(p.join(tmp.path, 'a.apk'), {
        'classes.dex': [1, 2, 3],
        'removed-in-b.dex': [9],
      });
      final b = _writeZip(p.join(tmp.path, 'b.apk'), {
        'classes.dex': [7, 8, 9],
        'added-in-b.dex': [1],
      });
      final diff = compareZipEntries(a.path, b.path);
      expect(diff.onlyInA, ['removed-in-b.dex']);
      expect(diff.onlyInB, ['added-in-b.dex']);
      expect(diff.changedContent, ['classes.dex']);
    });
  });

  group('compareArtifacts', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('oka-compare-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('equal badging and entries → no differences', () async {
      final a = _writeZip(p.join(tmp.path, 'a.apk'), {
        'classes.dex': [1],
      });
      final b = _writeZip(p.join(tmp.path, 'b.apk'), {
        'classes.dex': [1],
      });
      final cmp = await compareArtifacts(
        a.path,
        b.path,
        dumpBadging: (_, __) async => _badgingA,
      );
      expect(cmp.hasDifferences, isFalse);
      expect(cmp.badgingSkippedReason, isNull);
      expect(cmp.report(), contains('artifacts are equivalent'));
    });

    test('permission difference is reported and fails the gate', () async {
      final a = _writeZip(p.join(tmp.path, 'a.apk'), {
        'classes.dex': [1],
      });
      final b = _writeZip(p.join(tmp.path, 'b.apk'), {
        'classes.dex': [1],
      });
      final cmp = await compareArtifacts(
        a.path,
        b.path,
        dumpBadging: (__, artifact) async =>
            artifact == a.path ? _badgingA : _badgingB,
      );
      expect(cmp.hasDifferences, isTrue);
      expect(
        cmp.badgingDifferences.any((d) => d.contains('POST_NOTIFICATIONS')),
        isTrue,
      );
      expect(cmp.report(), contains('artifacts differ'));
    });

    test('version difference is reported', () async {
      final a = _writeZip(p.join(tmp.path, 'a.apk'), {
        'classes.dex': [1],
      });
      final b = _writeZip(p.join(tmp.path, 'b.apk'), {
        'classes.dex': [1],
      });
      final cmp = await compareArtifacts(
        a.path,
        b.path,
        dumpBadging: (__, artifact) async => artifact == a.path
            ? _badgingA
            : _badgingA.replaceFirst("versionCode='51'", "versionCode='52'"),
      );
      expect(
        cmp.badgingDifferences,
        contains('versionCode: 51 vs 52'),
      );
    });

    test('missing aapt2 skips badging but still diffs zip entries', () async {
      final a = _writeZip(p.join(tmp.path, 'a.apk'), {
        'classes.dex': [1],
      });
      final b = _writeZip(p.join(tmp.path, 'b.apk'), {});
      final cmp = await compareArtifacts(a.path, b.path, aapt2Path: null);
      expect(cmp.badgingSkippedReason, isNotNull);
      expect(cmp.badgingA, isNull);
      expect(cmp.zipDiff.onlyInA, ['classes.dex']);
      expect(cmp.hasDifferences, isTrue);
    });

    test('badging dump failure is captured as a skip reason', () async {
      final a = _writeZip(p.join(tmp.path, 'a.apk'), {
        'classes.dex': [1],
      });
      final cmp = await compareArtifacts(
        a.path,
        a.path,
        aapt2Path: '/does/not/matter',
        dumpBadging: (_, __) async => throw Exception('boom'),
      );
      expect(cmp.badgingSkippedReason, contains('boom'));
    });
  });
}
