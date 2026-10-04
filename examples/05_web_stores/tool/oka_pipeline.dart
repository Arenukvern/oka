/// Example 05 — the web shell station: per-store index.html as typed Dart,
/// plus deploy targets (GitHub Pages, itch.io). All dry-run by default.
///
///   oka run web-shell          # compose + emit web/index.html
///   oka run web-build          # honest delegation to flutter build web
///   oka run publish-gh-pages   # dry-run plan
library;

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';

/// The shell your app ships in — PWA identity, icons, head entries. Typed,
/// const, drift-checked: a hand-edit to web/index.html fails the next
/// `oka run web-shell` instead of silently drifting.
const shellSpec = WebShellSpec(
  name: 'Web Stores Oka',
  shortName: 'webstores',
  startUrl: '.',
  display: 'standalone',
  themeColor: '#02569B',
  backgroundColor: '#FFFFFF',
  description: 'Example 05 — one web shell, any storefront.',
);

Future<void> main(List<String> args) => okaRun(
  args,
  oka: const Oka(
    targets: [
      // Compose + emit web/index.html (no Flutter invocation).
      WebShellTarget(spec: shellSpec),
      // Storefront difference? Compose contributions here, e.g.:
      // WebShellTarget(
      //   spec: shellSpec,
      //   contributions: [MyStoreContribution()],
      // ),
      // The compile is a named delegation to flutter build web.
      WebBuildTarget(),
      // Deploys — destructive, so dry-run by default:
      GhPagesDeployTarget(),
      ItchDeployTarget(user: 'your-itch-user', game: 'webstores-oka'),
    ],
  ),
);
