import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

class ResolvedJar {
  const ResolvedJar({
    required this.coordinate,
    required this.jarPath,
    this.nativeLibsByAbi = const {},
    this.resDirs = const [],
  });

  final MavenCoordinate coordinate;
  final String jarPath;
  final Map<String, List<String>> nativeLibsByAbi;
  final List<String> resDirs;
}

Uint8List? tryExtractClassesJarFromAar(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive) {
    if (file.isFile &&
        (file.name == 'classes.jar' || file.name.endsWith('/classes.jar'))) {
      return Uint8List.fromList(file.content as List<int>);
    }
  }
  return null;
}

Uint8List extractClassesJarFromAar(List<int> bytes) {
  final jar = tryExtractClassesJarFromAar(bytes);
  if (jar == null) throw Exception('classes.jar not found in AAR');
  return jar;
}

Future<String> extractClassesJarToFile(
  List<int> bytes,
  String destination,
) async {
  await File(destination).parent.create(recursive: true);
  await File(
    destination,
  ).writeAsBytes(extractClassesJarFromAar(bytes), flush: true);
  return destination;
}

Future<({Map<String, List<String>> nativeLibsByAbi, List<String> resDirs})>
extractAarPayload(
  List<int> bytes,
  String destination, {
  bool verbose = false,
}) async {
  final archive = ZipDecoder().decodeBytes(bytes);
  final natives = <String, List<String>>{};
  var hasResources = false;
  for (final file in archive) {
    if (!file.isFile) continue;
    final name = file.name.replaceAll(r'\', '/');
    final native = RegExp(r'^jni/([^/]+)/(lib[^/]+[.]so)$').firstMatch(name);
    if (native != null) {
      final output = p.join(destination, name);
      await File(output).parent.create(recursive: true);
      await File(output).writeAsBytes(file.content as List<int>, flush: true);
      natives.putIfAbsent(native.group(1)!, () => []).add(output);
    } else if (name.startsWith('res/') && name.endsWith('.xml')) {
      hasResources = true;
      final output = p.join(destination, name);
      await File(output).parent.create(recursive: true);
      await File(output).writeAsBytes(file.content as List<int>, flush: true);
    }
  }
  for (final paths in natives.values) {
    paths.sort();
  }
  final resources = hasResources
      ? [p.join(destination, 'res')]
      : const <String>[];
  if (verbose && (natives.isNotEmpty || resources.isNotEmpty)) {
    final count = natives.values.fold<int>(
      0,
      (sum, paths) => sum + paths.length,
    );
    print('   AAR payload: $count natives, ${resources.length} res dir(s)');
  }
  return (nativeLibsByAbi: natives, resDirs: resources);
}

List<int> minimalJarBytes({String entryName = 'META-INF/MANIFEST.MF'}) {
  final archive = Archive();
  const manifest = 'Manifest-Version: 1.0\n\n';
  archive.addFile(ArchiveFile(entryName, manifest.length, manifest.codeUnits));
  return ZipEncoder().encodeBytes(archive);
}

List<int> minimalAarBytes() {
  final classes = minimalJarBytes();
  final archive = Archive()
    ..addFile(ArchiveFile('classes.jar', classes.length, classes))
    ..addFile(ArchiveFile('AndroidManifest.xml', 11, '<manifest/>'.codeUnits));
  return ZipEncoder().encodeBytes(archive);
}
