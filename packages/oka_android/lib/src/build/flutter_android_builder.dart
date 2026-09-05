import 'package:oka_core/src/config/build_context.dart';
import 'flutter_apk_builder.dart';
import 'sdk_locator.dart';

/// Compatibility wrapper: hybrid cargo-apk path is **demoted**.
///
/// All builds delegate to [FlutterApkBuilder] (no-Gradle Java embedding).
/// This class no longer:
/// - mutates shared `rust_wrapper/Cargo.toml`
/// - falls back to `flutter build apk` (Gradle)
/// - invokes cargo-apk
///
/// Kept so older imports continue to resolve.
class FlutterAndroidBuilder {
  final SdkLocator _sdkLocator;
  final bool _verbose;

  FlutterAndroidBuilder(this._sdkLocator, {bool verbose = false})
      : _verbose = verbose;

  /// Build Flutter APK using the no-Gradle SDK-tools pipeline only.
  Future<BuildArtifact> buildFlutterApk(BuildContext ctx) {
    if (_verbose) {
      print(
        'ℹ️  cargo-apk hybrid path is demoted; using no-Gradle FlutterApkBuilder',
      );
    }
    return FlutterApkBuilder(_sdkLocator, verbose: _verbose).buildApk(ctx);
  }

  /// Install helper retained for API compatibility.
  Future<void> installAndRun(BuildContext ctx, String apkPath) async {
    final adb = await _sdkLocator.findAdb();
    // ignore: avoid_print
    print('📱 adb install -r $apkPath (via $adb)');
    // Actual install left to callers; keep method for compatibility.
  }
}
