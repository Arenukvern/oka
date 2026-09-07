/// Tool-resolution contracts (ADR-0013, decision 1).
///
/// Resolution policy is **data**, not control flow: an ordered list of
/// candidate [ToolSource]s that is printable (`oka doctor`), testable
/// (injected environment), and composable. A [Toolchain] returns both the
/// result and the candidates it tried, so errors can name the fix
/// (ADR-0007) without re-deriving the policy.
library;

import 'package:meta/meta.dart';

/// Where a tool may come from, in descending order of preference.
enum ToolSourceKind {
  /// Explicit configuration (typed Dart config / oka.yaml).
  config,

  /// Environment variable (`OKA_ANDROID_SDK`, `ANDROID_HOME`, `JAVA_HOME`…).
  env,

  /// Oka-managed install root (`~/.oka/android-sdk`, `~/.oka/tools`, or the
  /// shared artifact store).
  managed,

  /// System-wide location (`PATH`, common install directories).
  system,
}

/// One ordered candidate source inside a resolution policy.
///
/// A plain value: [kind] classifies it, [label] is the human-decodable name
/// printed by `oka doctor` and in [ToolchainException] output.
@immutable
class ToolSource {
  const ToolSource(this.kind, this.label);

  final ToolSourceKind kind;
  final String label;

  /// Printable kind prefix, e.g. `env OKA_ANDROID_SDK`.
  String get qualified => '${kind.name} $label';

  @override
  String toString() => qualified;

  @override
  bool operator ==(final Object other) =>
      other is ToolSource && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(kind, label);
}

/// Name of a tool to resolve, e.g. `aapt2`, `d8`, `javac`, `kotlinc`, `adb`.
@immutable
class ToolQuery {
  const ToolQuery(this.name);

  final String name;

  @override
  String toString() => name;

  @override
  bool operator ==(final Object other) =>
      other is ToolQuery && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// A tool the policy actually resolved: where it lives and where it came
/// from.
@immutable
class ResolvedTool {
  const ResolvedTool({
    required this.name,
    required this.path,
    required this.source,
    this.version,
  });

  /// Tool name (matches the [ToolQuery.name] that produced it).
  final String name;

  /// Absolute path of the resolved tool (or SDK root for umbrella queries).
  final String path;

  /// Upstream version when the policy knows one (e.g. the build-tools
  /// directory name for `aapt2` / `d8`).
  final String? version;

  /// Which candidate source resolved it.
  final ToolSource source;

  @override
  String toString() => '$name → $path (${source.qualified})';

  @override
  bool operator ==(final Object other) =>
      other is ResolvedTool &&
      other.name == name &&
      other.path == path &&
      other.version == version &&
      other.source == source;

  @override
  int get hashCode => Object.hash(name, path, version, source);
}

/// Outcome of evaluating a [Toolchain] policy for one [ToolQuery].
///
/// Always carries the ordered [tried] candidates — on failure this is the
/// material for errors and doctor output; on success it documents the
/// decision path.
@immutable
class ToolResolution {
  const ToolResolution({this.tool, this.tried = const <ToolSource>[], this.problem});

  final ResolvedTool? tool;
  final List<ToolSource> tried;

  /// Why resolution failed (headline for errors/doctor); null on success.
  final String? problem;

  bool get ok => tool != null;

  @override
  String toString() => ok ? tool.toString() : (problem ?? 'not found (tried: $tried)');
}

/// Thrown when a required tool cannot be resolved: names every candidate
/// tried, in order, plus the remediation (ADR-0007: errors name the fix).
class ToolchainException implements Exception {
  ToolchainException({
    required this.tool,
    required this.tried,
    required this.fix,
    this.problem,
  });

  /// Tool name that failed to resolve.
  final String tool;

  /// Ordered candidate sources attempted before failing.
  final List<ToolSource> tried;

  /// The remediation — what to run/set to make resolution succeed.
  final String fix;

  /// Headline; defaults to `Tool '<tool>' not found.` Callers may override
  /// with a domain-specific headline (e.g. `Android SDK not found.`).
  final String? problem;

  @override
  String toString() {
    final b = StringBuffer(problem ?? "Tool '$tool' not found.");
    if (tried.isNotEmpty) {
      b.write('\nTried (in order):');
      for (var i = 0; i < tried.length; i++) {
        b.write('\n  ${i + 1}. ${tried[i].qualified}');
      }
    }
    b.write('\nFix: $fix');
    return b.toString();
  }
}

/// Ordered, printable tool-resolution policy (ADR-0013, decision 1).
///
/// Implementations own the probes; the policy itself is inspectable as a
/// value via [describe] — a list of ordered candidate sources, never buried
/// in if-chains. No interactive anything: resolution never reads stdin.
abstract interface class Toolchain {
  /// The policy for [query] as a value: ordered candidate sources, most
  /// preferred first.
  List<ToolSource> describe(final ToolQuery query);

  /// Evaluate the policy for [query], returning both the result and the
  /// candidates tried (for errors and `oka doctor` output).
  ///
  /// Never throws: a failed resolution is a [ToolResolution] with
  /// [ToolResolution.problem] set. Required tools go through `require` —
  /// implementations conventionally pair `resolve` with a throwing variant.
  Future<ToolResolution> resolve(final ToolQuery query);
}
