/// Compatibility facade: browser ownership/discovery lives in oka_web.
library;

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';

export 'package:oka_web/oka_web.dart' show BrowserSessionSpec;

typedef DevBrowserLauncher =
    Future<DevBrowserSession> Function({
      required String project,
      required Uri appUrl,
      required BrowserSessionSpec spec,
    });

class DevBrowserSession {
  const DevBrowserSession({required this.pageWsUrl, required this.stop});
  final String pageWsUrl;
  final Future<void> Function() stop;
}

Future<DevBrowserSession> launchDevBrowser({
  required String project,
  required Uri appUrl,
  required BrowserSessionSpec spec,
}) async {
  final session = await startBrowserPageSession(
    context: BuildContext(
      projectPath: project,
      buildDir: '$project/.oka_cache/dev-browser',
      mode: BuildMode.debug,
      config: OkaConfig.empty,
    ),
    appUrl: appUrl,
    spec: spec,
    sessionName: 'dev-${DateTime.now().microsecondsSinceEpoch}',
  );
  return DevBrowserSession(pageWsUrl: session.pageWsUrl, stop: session.stop);
}
