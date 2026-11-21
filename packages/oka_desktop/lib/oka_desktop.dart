/// Desktop platform pipelines for oka (ADR-0055): macOS, Linux, and
/// Windows builds over flutter's own desktop toolchain.
///
/// Each pipeline is an **honest delegation** to
/// `flutter build <desktop>` (named as delegation, never claimed as an
/// oka-owned pipeline — the ADR-0016 web law carried to desktop). Delivery
/// variants apply before the run: the entrypoint arrives through the
/// build context (`--target` resolution order), defines through
/// `--dart-define`.
///
/// ```dart
/// import 'package:oka_core/oka_core.dart';
/// import 'package:oka_desktop/oka_desktop.dart';
///
/// Future<void> main(List<String> args) => okaRun(
///       args,
///       oka: const Oka(
///         pipelines: [MacosPipeline()],
///         targets: [
///           Delivery(
///             name: 'app-apple-store',
///             pipeline: MacosPipeline(),
///             variant: Variant(key: storeKeyAppleStore),
///           ),
///         ],
///       ),
///     );
/// ```
///
/// See also:
///
/// * ADR-0055 — the buildable × pipeline × variant × channel model.
/// * Snap/msix/notarization channels: roadmap rows, composed onto these
///   pipelines as [PublishTarget]s when built.
library;

export 'src/pipeline/flutter_desktop_pipeline.dart';
