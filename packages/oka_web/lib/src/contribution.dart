/// The store-contribution contract (ADR-0016 §1/§3): the "what" seam.
///
/// A [WebShellContribution] is a typed, const-constructible description of
/// *what* a store (or the project, or an oka station) adds to the web
/// shell: ordered head entries, body entries, PWA manifest overrides, and
/// optional base-href / dart-define overrides. Contributions are composed
/// explicitly by the user in the composition root — **no hidden merging**
/// (ADR-0010): if two contributions conflict, the last declaration wins
/// for scalar overrides, and both stay in the entry list.
library;

import 'package:meta/meta.dart';

import 'spec/body_entry.dart';
import 'spec/head_entry.dart';
import 'spec/web_shell_spec.dart';

/// Typed, const-constructible store/project shell contribution
/// (ADR-0016).
///
/// Third-party store packages ship const subclasses; the user composes
/// them in the composition root:
///
/// ```dart
/// class YandexGamesContribution extends WebShellContribution {
///   const YandexGamesContribution({this.sandbox = false});
///   final bool sandbox;
///
///   @override
///   List<WebHeadEntry> get head => [
///         WebScriptEntry(
///           src: 'https://yandex.ru/games/sdk/v2',
///           phase: WebHeadPhase.storeSdk,
///           requiredSdkGlobal: 'YaGames',
///         ),
///       ];
/// }
/// ```
abstract class WebShellContribution {
  const WebShellContribution();

  /// Head entries this contribution contributes. Ordered among all
  /// contributions by [WebHeadPhase], then declaration order.
  List<WebHeadEntry> get head => const [];

  /// Body entries this contribution contributes (loading containers,
  /// noscript blocks).
  List<WebBodyEntry> get body => const [];

  /// Optional PWA manifest field overrides.
  PwaManifestOverride? get manifest => null;

  /// Optional base-href override (e.g. a store serves the game from a
  /// subpath). Null = no override.
  String? get baseHref => null;

  /// Optional dart-define overrides applied to `flutter build web`.
  /// Later contributions override earlier ones (explicit composition).
  Map<String, String> get dartDefines => const {};
}

/// A ready-made const contribution for simple declarations.
///
/// Lets a store package ship its contribution as a single const value
/// without subclassing:
///
/// ```dart
/// const crazyGames = SimpleWebShellContribution(
///   head: [
///     WebScriptEntry(src: 'https://api.crazygames.com/sdk.js', ...),
///   ],
/// );
/// ```
@immutable
class SimpleWebShellContribution extends WebShellContribution {
  const SimpleWebShellContribution({
    this.head = const [],
    this.body = const [],
    this.manifest,
    this.baseHref,
    this.dartDefines = const {},
  });

  @override
  final List<WebHeadEntry> head;

  @override
  final List<WebBodyEntry> body;

  @override
  final PwaManifestOverride? manifest;

  @override
  final String? baseHref;

  @override
  final Map<String, String> dartDefines;
}
