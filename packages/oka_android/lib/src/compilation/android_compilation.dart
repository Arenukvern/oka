import 'package:oka_core/oka_core.dart';

import '../build/toolchain.dart';
import 'bytecode_compilation.dart';
import 'process_runner.dart';
import 'resource_compilation.dart';

Future<CompileDexOutcome> compileAndDex({
  required BuildContext ctx,
  required ResolvedToolchain toolchain,
  required String hostDir,
  required String embeddingJar,
  required List<String> androidxJarPaths,
  List<String> pluginJavaSources = const [],
  List<String> pluginKotlinSources = const [],
  List<String> pluginJarDeps = const [],
  List<String> pluginResDirs = const [],
  List<String> resourceConfigs = const [],
  String? versionCode,
  String? versionName,
  int? javaVersionOverride,
  AndroidProcessRunner processRunner = runAndroidProcess,
}) => _compile(
  ctx: ctx,
  toolchain: toolchain,
  format: AndroidResourceFormat.apk,
  hostDir: hostDir,
  embeddingJar: embeddingJar,
  androidxJarPaths: androidxJarPaths,
  pluginJavaSources: pluginJavaSources,
  pluginKotlinSources: pluginKotlinSources,
  pluginJarDeps: pluginJarDeps,
  pluginResDirs: pluginResDirs,
  resourceConfigs: resourceConfigs,
  versionCode: versionCode,
  versionName: versionName,
  javaVersionOverride: javaVersionOverride,
  processRunner: processRunner,
);

Future<CompileDexOutcome> compileAndDexProto({
  required BuildContext ctx,
  required ResolvedToolchain toolchain,
  required String hostDir,
  required String embeddingJar,
  required List<String> androidxJarPaths,
  List<String> pluginJavaSources = const [],
  List<String> pluginKotlinSources = const [],
  List<String> pluginJarDeps = const [],
  List<String> pluginResDirs = const [],
  List<String> resourceConfigs = const [],
  String? versionCode,
  String? versionName,
  int? javaVersionOverride,
  AndroidProcessRunner processRunner = runAndroidProcess,
}) => _compile(
  ctx: ctx,
  toolchain: toolchain,
  format: AndroidResourceFormat.protoBundle,
  hostDir: hostDir,
  embeddingJar: embeddingJar,
  androidxJarPaths: androidxJarPaths,
  pluginJavaSources: pluginJavaSources,
  pluginKotlinSources: pluginKotlinSources,
  pluginJarDeps: pluginJarDeps,
  pluginResDirs: pluginResDirs,
  resourceConfigs: resourceConfigs,
  versionCode: versionCode,
  versionName: versionName,
  javaVersionOverride: javaVersionOverride,
  processRunner: processRunner,
);

Future<CompileDexOutcome> _compile({
  required BuildContext ctx,
  required ResolvedToolchain toolchain,
  required AndroidResourceFormat format,
  required String hostDir,
  required String embeddingJar,
  required List<String> androidxJarPaths,
  required List<String> pluginJavaSources,
  required List<String> pluginKotlinSources,
  required List<String> pluginJarDeps,
  required List<String> pluginResDirs,
  required List<String> resourceConfigs,
  required String? versionCode,
  required String? versionName,
  required int? javaVersionOverride,
  required AndroidProcessRunner processRunner,
}) async {
  final resources = await compileAndroidResources(
    ctx: ctx,
    toolchain: toolchain,
    format: format,
    pluginResDirs: pluginResDirs,
    resourceConfigs: resourceConfigs,
    versionCode: versionCode,
    versionName: versionName,
    processRunner: processRunner,
  );
  if (!resources.ok) {
    return CompileDexOutcome(ok: false, error: resources.error);
  }
  try {
    final tools = await resolveBytecodeTools(
      toolchain,
      needsKotlin: pluginKotlinSources.isNotEmpty,
    );
    return await compileAndroidBytecode(
      ctx: ctx,
      tools: tools,
      hostDir: hostDir,
      generatedSourcesDir: resources.generatedSourcesDir!,
      androidJar: resources.androidJar!,
      embeddingJar: embeddingJar,
      dependencyJars: [...androidxJarPaths, ...pluginJarDeps],
      pluginJavaSources: pluginJavaSources,
      pluginKotlinSources: pluginKotlinSources,
      javaVersionOverride: javaVersionOverride,
      processRunner: processRunner,
    );
  } on Exception catch (error) {
    return CompileDexOutcome(ok: false, error: error.toString());
  }
}
