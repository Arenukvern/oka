/// CrazyGames store contribution — the flagship third-party pattern example
/// (ADR-0016 §3 pilot).
///
/// This file is the third-party extension-point pilot: it shows exactly
/// what a store package ships alongside its runtime adapter — a typed,
/// const-constructible [WebShellContribution] whose ordered entries replace
/// the README-driven "prerequisite in `web/index.html`" snippet with
/// something verifiable. The store SDK ground truth (script URL, SDK
/// version, expected global) is locked upstream by the CrazyGames Dart
/// bindings package's `upstream_lock.json` (`sdkUrl`:
/// `https://sdk.crazygames.com/crazygames-sdk-v3.js`, SDK v3); the runtime
/// adapter's `expectedSdkGlobal` (`CrazyGames`, i.e. `window.CrazyGames`)
/// and this contribution's [requiredSdkGlobal] are the SAME constant
/// reconciled at build time instead of two independent sources (ADR-0016
/// §3).
///
/// **Why this lives in `example/` and not `lib/src/`:** in production a
/// store package (e.g. the CrazyGames platform/runtime package) ships this
/// const alongside its runtime adapter — the ADR-0016 §3 extension point.
/// It is an example here because `oka_web` is not yet published on
/// pub.dev, and store packages must not depend on unpublished packages.
/// (The former Yandex Games example now lives in the migrating app's own
/// repo, adopted via the inject emitter — stores' contributions belong to
/// the packages and apps that own them.) The *shape* is exactly what those
/// packages export: a const class, no I/O, no state, composed explicitly
/// by the user in the composition root (ADR-0010 — no hidden merging).
///
/// Ordering constraints encoded by phases ([WebHeadPhase]):
///
/// 1. `preconnect` — warm `sdk.crazygames.com` (TLS + connection) before
///    the SDK script is requested.
/// 2. `storeSdk` — the CrazyGames HTML5 SDK v3 script; it must load before
///    any app glue touches the `CrazyGames` global (declared via
///    [WebScriptEntry.requiredSdkGlobal] so `oka doctor` / the shell gate
///    can reconcile build-time knowledge with the runtime adapter's
///    `expectedSdkGlobal: 'CrazyGames'` instead of duplicating it).
///
/// **No dev/QA tool script entry:** the CrazyGames Dart bindings package
/// documents no separate QA-tool script — the SDK object itself reports
/// whether the session runs inside the CrazyGames QA tool at runtime
/// (`isQaTool`). Local QA therefore needs no typed shell entry; if a
/// script-based QA harness appears, add it here as a typed, default-off
/// option (e.g. `includeQaTool`) rather than editing HTML.
///
/// **No PWA manifest override** — see [manifest] for the rationale.
library;

import 'package:meta/meta.dart';
import 'package:oka_web/oka_web.dart';

/// The CrazyGames store contribution (ADR-0016 §3 pilot, flagship example).
///
/// Const-constructible; the user composes it explicitly:
///
/// ```dart
/// const target = WebShellTarget(
///   spec: WebShellSpec(title: 'Word by Word — CrazyGames'),
///   contributions: [CrazyGamesShellContribution()],
/// );
/// ```
@immutable
class CrazyGamesShellContribution extends WebShellContribution {
  /// Const constructor — compose with explicit, reviewed values.
  const CrazyGamesShellContribution();

  /// CrazyGames HTML5 SDK v3 script URL (the URL the CrazyGames Dart
  /// bindings package locks in `upstream_lock.json`, SDK v3).
  static const String sdkUrl =
      'https://sdk.crazygames.com/crazygames-sdk-v3.js';

  /// The global the SDK script defines: `window.CrazyGames`. Declared here
  /// (build time) so doctor/gates can check the runtime adapter's
  /// `expectedSdkGlobal` against the shell instead of trusting two
  /// independent sources (ADR-0016 §3 reconciliation).
  static const String requiredSdkGlobal = 'CrazyGames';

  @override
  List<WebHeadEntry> get head => const [
        // Phase 1 — preconnect: the origin the SDK script is served from.
        WebLinkEntry(
          rel: 'preconnect',
          href: 'https://sdk.crazygames.com/',
          phase: WebHeadPhase.preconnect,
        ),
        // Phase 2 — the store SDK, before anything app-owned touches it.
        WebScriptEntry(
          src: sdkUrl,
          phase: WebHeadPhase.storeSdk,
          requiredSdkGlobal: requiredSdkGlobal,
        ),
      ];

  /// No PWA manifest override — deliberately.
  ///
  /// CrazyGames serves the game inside its own site chrome (a fullscreen
  /// iframe on its store pages), so manifest `display`/`orientation` have
  /// no effect there; overriding them "because store" would silently
  /// change the manifest for every other deployment target composed with
  /// this contribution (ADR-0010: explicit composition, no hidden
  /// merging). If a real store requirement appears, add a minimal
  /// [PwaManifestOverride] here — with the store evidence next to it —
  /// instead of editing `manifest.json` per branch.
  @override
  PwaManifestOverride? get manifest => null;

  @override
  String toString() => 'CrazyGamesShellContribution($sdkUrl)';
}
