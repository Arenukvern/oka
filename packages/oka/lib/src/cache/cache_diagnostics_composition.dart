import 'package:oka_android/oka_android.dart';
import 'package:oka_web/oka_web.dart';

import 'host_adapters/apple_cache_diagnostics.dart';
import 'host_adapters/foreign_store_diagnostics.dart';

/// First-party composition. Package developers may use, replace or extend it.
List<CacheDiagnosticProvider> defaultCacheDiagnosticProviders() => [
  const CoreCacheDiagnosticProvider(),
  const AndroidCacheDiagnosticProvider(),
  const BrowserCacheDiagnosticProvider(),
  const AppleCacheDiagnosticProvider(),
  const ForeignStoreDiagnosticProvider(),
];
