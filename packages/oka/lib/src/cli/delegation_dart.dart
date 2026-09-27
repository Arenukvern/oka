import 'dart:io';

import 'package:oka_android/oka_android.dart';

/// The Dart executable the delegated pipeline (`dart run
/// tool/oka_pipeline.dart`) runs under.
///
/// Build hooks locate the Flutter SDK cache by walking the RUNNING
/// executable's path (flutter_gpu_shaders' `findEngineArtifactsDir` —
/// flutter_scene's shader bundle needs it), so the delegation must run
/// under the Flutter SDK's own dart. A PATH/pub-global dart breaks those
/// hooks with "Unable to find Flutter SDK cache directory". This is the
/// same SDK-path-never-PATH law the dev session applies to the flutter
/// binary (ADR-0011). Falls back to PATH `dart` when no Flutter SDK is
/// locatable (SDK-less full-Dart projects carry no Flutter hooks).
Future<String> resolveDelegationDart() async {
  try {
    final flutterSdk = await SdkLocator().findFlutterSdk();
    final sdkDart = File('$flutterSdk/bin/cache/dart-sdk/bin/dart');
    if (sdkDart.existsSync()) return sdkDart.path;
  } on Object {
    // No Flutter SDK: PATH dart is the honest fallback.
  }
  return 'dart';
}
