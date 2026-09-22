/// Compatibility facade for Android compilation, packaging and signing.
///
/// Capability implementations live under named owners. Existing internal and
/// package imports keep working through these exports.
library;

export '../compilation/android_compilation.dart';
export '../compilation/bytecode_compilation.dart';
export '../compilation/process_runner.dart';
export '../compilation/resource_compilation.dart';
export '../packaging/aab_packaging.dart';
export '../packaging/apk_packaging.dart';
export '../signing/android_signing.dart';
