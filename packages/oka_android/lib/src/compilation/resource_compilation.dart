import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../build/aapt2_commands.dart';
import '../build/toolchain.dart';
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
    final resDir = p.join(ctx.buildDir, 'res');
    for (final pluginRes in pluginResDirs) {
      final source = Directory(pluginRes);
      if (await source.exists()) {
        await copyDirectory(source, Directory(resDir));
      }
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
    return ResourceCompilationOutcome(
      ok: true,
      androidJar: androidJar,
      generatedSourcesDir: generated,
    );
  } on Exception catch (error) {
    return ResourceCompilationOutcome(ok: false, error: error.toString());
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
