# oka_desktop

Desktop platform pipelines for [oka](https://github.com/Arenukvern/oka)
(ADR-0055): macOS, Linux, and Windows build pipelines over Flutter's own
desktop toolchain — honest delegation, typed artifacts, delivery-ready.

```dart
import 'package:oka_desktop/oka_desktop.dart';

const Oka(
  pipelines: [MacosPipeline(), LinuxPipeline(), WindowsPipeline()],
);
```

Each pipeline delegates to `flutter build <macos|linux|windows>` with the
delivery variant already applied to the context (entrypoint → `--target`,
defines → `--dart-define`, flavor → `--flavor`), provides a typed artifact
(`macos-app-bundle`, `linux-bundle`, `windows-bundle`), and fails the step
when the tool exits green but the expected artifact directory is missing.
Delegation is named as delegation: the native desktop toolchain stays
Flutter's until oka owns one.

Publish tails (snap, msix/Partner Center, notarized DMG, Steam depots) are
channels composed onto deliveries — see oka's ADR-0055; none ship here yet.
