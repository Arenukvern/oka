import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../build/aapt2_commands.dart';
import '../build/toolchain.dart';
import 'manifest_merge.dart';
import 'process_runner.dart';

enum AndroidResourceFormat { apk, protoBundle }

class ResourceCompilationOutcome {
  const ResourceCompilationOutcome({
    required this.ok,
    this.error,
    this.androidJar,
    this.generatedSourcesDir,
  });

  final bool ok;
  final String? error;
  final String? androidJar;
  final String? generatedSourcesDir;
}

Future<ResourceCompilationOutcome> compileAndroidResources({
  required BuildContext ctx,
  required ResolvedToolchain toolchain,
  required AndroidResourceFormat format,
  List<String> pluginResDirs = const [],
  List<String> resourceConfigs = const [],
  String? versionCode,
  String? versionName,
  AndroidProcessRunner processRunner = runAndroidProcess,
}) async {
  try {
    final aapt2 = await toolchain.findAapt2();
    final androidSdk = await toolchain.findAndroidSdk();
    final compileSdk = ctx.config.android.compileSdk.isEmpty
        ? '34'
        : ctx.config.android.compileSdk;
    final androidJar = await resolveAndroidJar(androidSdk, compileSdk);
    // Each res source compiles to its own zip and links as an overlay:
    // same-named FILEs (values.xml, values-v21.xml, …) from different AARs
    // no longer clobber each other in one shared tree — aapt2 merges at the
    // resource level with later -R zips overriding earlier ones. The primary
    // res dir (codegen + project res) is passed last by the link builders so
    // app resources win over AAR/plugin resources.
    final resDir = p.join(ctx.buildDir, 'res');
    final overlayZips = <String>[];
    final compiledZipByDir = <String, String>{};
    for (var i = 0; i < pluginResDirs.length; i++) {
      final source = Directory(pluginResDirs[i]);
      if (!await source.exists()) continue;
      final zip = p.join(ctx.buildDir, 'compiled_res_$i.zip');
      if (await File(zip).exists()) await File(zip).delete();
      final compile = await processRunner(
        aapt2,
        buildAapt2CompileDirArgs(
          resDir: pluginResDirs[i],
          compiledResourcesZip: zip,
        ),
      );
      if (compile.exitCode != 0) {
        return ResourceCompilationOutcome(
          ok: false,
          error:
              'aapt2 compile failed for res dir ${pluginResDirs[i]}: '
              '${compile.stderr}',
        );
      }
      overlayZips.add(zip);
      compiledZipByDir[pluginResDirs[i]] = zip;
    }

    final compiledResources = p.join(ctx.buildDir, 'compiled_resources.zip');
    await Directory(p.dirname(compiledResources)).create(recursive: true);
    final compiledFile = File(compiledResources);
    if (await compiledFile.exists()) await compiledFile.delete();
    final compile = await processRunner(
      aapt2,
      buildAapt2CompileDirArgs(
        resDir: resDir,
        compiledResourcesZip: compiledResources,
      ),
    );
    if (compile.exitCode != 0) {
      return ResourceCompilationOutcome(
        ok: false,
        error: 'aapt2 compile failed: ${compile.stderr}',
      );
    }
    if (!await compiledFile.exists()) {
      return ResourceCompilationOutcome(
        ok: false,
        error:
            'aapt2 compile did not produce compiled-resources zip at '
            '$compiledResources',
      );
    }

    final generated = p.join(ctx.buildDir, 'gen');
    await Directory(generated).create(recursive: true);
    final manifest = p.join(ctx.buildDir, 'AndroidManifest.xml');
    // Merge AAR manifests into the app manifest before link: aapt2 will not
    // do it, and libraries that declare runtime components break at runtime
    // when the components are missing (e.g. CameraX's MetadataHolderService
    // → NameNotFoundException → camera_start_failed).
    final libraryManifests = [
      for (final resDir in compiledZipByDir.keys)
        p.join(p.dirname(resDir), 'AndroidManifest.xml'),
    ]..removeWhere((final f) => !File(f).existsSync());
    if (libraryManifests.isNotEmpty && File(manifest).existsSync()) {
      final merged = mergeLibraryManifestsInto(
        appManifestPath: manifest,
        libraryManifestPaths: libraryManifests,
      );
      if (merged > 0) {
        stdout.writeln(
          'oka: merged $merged manifest element(s) from '
          '${libraryManifests.length} library manifest(s)',
        );
      }
    }
    final output = p.join(
      ctx.buildDir,
      format == AndroidResourceFormat.apk
          ? 'resources.ap_'
          : 'resources_proto.ap_',
    );
    final linkArgs = format == AndroidResourceFormat.apk
        ? buildAapt2LinkArgs(
            androidJar: androidJar,
            manifestPath: manifest,
            outputAp: output,
            compiledResourcesZip: compiledResources,
            overlayZips: overlayZips,
            javaOutDir: generated,
            resourceConfigs: resourceConfigs,
            versionCode: versionCode,
            versionName: versionName,
          )
        : buildAapt2LinkProtoFormatArgs(
            androidJar: androidJar,
            manifestPath: manifest,
            outputAp: output,
            compiledResourcesZip: compiledResources,
            overlayZips: overlayZips,
            javaOutDir: generated,
            resourceConfigs: resourceConfigs,
            versionCode: versionCode,
            versionName: versionName,
          );
    final link = await processRunner(aapt2, linkArgs);
    if (link.exitCode != 0) {
      final label = format == AndroidResourceFormat.apk
          ? 'aapt2 link'
          : 'aapt2 link --proto-format';
      return ResourceCompilationOutcome(
        ok: false,
        error: '$label failed: ${link.stderr}',
      );
    }

    // aapt2 link emits R.java only for the manifest package. AAR payloads
    // ship no compiled R, so generate one per library package from its own
    // AndroidManifest.xml — the same regeneration Gradle performs. Without
    // this, bytecode compiled against e.g. androidx.core's `R$id` crashes
    // with NoClassDefFoundError at runtime.
    await _generateLibraryRClasses(
      aapt2: aapt2,
      androidJar: androidJar,
      compiledZipByDir: compiledZipByDir,
      generatedSourcesDir: generated,
      processRunner: processRunner,
    );
    return ResourceCompilationOutcome(
      ok: true,
      androidJar: androidJar,
      generatedSourcesDir: generated,
    );
  } on Exception catch (error) {
    return ResourceCompilationOutcome(ok: false, error: error.toString());
  }
}

Future<void> _generateLibraryRClasses({
  required final String aapt2,
  required final String androidJar,
  required final Map<String, String> compiledZipByDir,
  required final String generatedSourcesDir,
  required final AndroidProcessRunner processRunner,
}) async {
  if (compiledZipByDir.isEmpty) return;
  stdout.writeln(
    'oka: generating R for ${compiledZipByDir.length} library package(s)',
  );
  for (final entry in compiledZipByDir.entries) {
    // res dir layout: <aar payload dir>/res → manifest sits beside it.
    final manifest = p.join(p.dirname(entry.key), 'AndroidManifest.xml');
    if (!File(manifest).existsSync()) continue;
    final output = '${entry.value}.r.ap';
    final link = await processRunner(
      aapt2,
      [
        'link',
        '-I',
        androidJar,
        '--manifest',
        manifest,
        '--java',
        generatedSourcesDir,
        '--auto-add-overlay',
        '-o',
        output,
        '-R',
        entry.value,
      ],
    );
    if (link.exitCode != 0) {
      // A package whose resources cannot stand alone contributes no R; the
      // classes referencing it would already fail at javac time otherwise.
      stderr.writeln(
        'oka: per-library R generation skipped for ${entry.key}: '
        '${link.stderr}',
      );
      continue;
    }
    final ap = File(output);
    if (await ap.exists()) await ap.delete();
  }
}

Future<String> resolveAndroidJar(String androidSdk, String compileSdk) async {
  final preferred = p.join(
    androidSdk,
    'platforms',
    'android-$compileSdk',
    'android.jar',
  );
  if (await File(preferred).exists()) return preferred;
  final platforms = Directory(p.join(androidSdk, 'platforms'));
  if (!await platforms.exists()) {
    throw Exception(
      'android.jar not found at $preferred and no platforms/ under $androidSdk. '
      'Run: oka get android-sdk',
    );
  }
  final jars = <String>[];
  await for (final entry in platforms.list()) {
    if (entry is Directory) {
      final jar = p.join(entry.path, 'android.jar');
      if (await File(jar).exists()) jars.add(jar);
    }
  }
  if (jars.isEmpty) {
    throw Exception(
      'android.jar not found for compileSdk $compileSdk at $preferred',
    );
  }
  jars.sort();
  final fallback = jars.last;
  print(
    '⚠️  Platform android-$compileSdk missing; using '
    '${p.basename(p.dirname(fallback))}',
  );
  return fallback;
}

/// Copies a res tree into [destination] (used by host codegen to stage user
/// `resDirs` into the primary build res dir; later copies override earlier
/// files, which is the intended user-over-generated precedence).
Future<void> copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entry in source.list(recursive: true, followLinks: false)) {
    final output = p.join(
      destination.path,
      p.relative(entry.path, from: source.path),
    );
    if (entry is Directory) {
      await Directory(output).create(recursive: true);
    } else if (entry is File) {
      await File(output).parent.create(recursive: true);
      await entry.copy(output);
    }
  }
}
