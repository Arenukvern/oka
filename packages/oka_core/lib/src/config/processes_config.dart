import 'package:from_json_to_json/from_json_to_json.dart';

/// The `oka.yaml` `processes.reap` section (ADR-0053): workspace-declared
/// extensions to the foreign orphan reaper's family and protected names.
///
/// Library defaults stay SDK/oka-universal
/// ([defaultForeignOrphanTargets], `defaultForeignOrphanProtected`);
/// machine-local ecosystem names — MCP servers, resident daemons, agent
/// tooling — are declared here per workspace instead of being hardcoded
/// into the library, so `oka processes reap` runs on any computer.
///
/// ```yaml
/// processes:
///   reap:
///     targets: [flutter-mcp-toolkit-server]
///     protected: [my_warm_daemon]
/// ```
extension type const ProcessesReapConfig(Map<String, dynamic> value) {
  /// Decodes from the `oka.yaml` `processes` payload map.
  factory ProcessesReapConfig.fromJson(Object? json) =>
      ProcessesReapConfig(jsonDecodeMap(json));

  static const empty = ProcessesReapConfig({});

  /// The `reap` section of the `processes` map.
  Map<String, dynamic> get _reap => jsonDecodeMap(value['reap']);

  /// Extra target command-line substrings, added to
  /// [defaultForeignOrphanTargets] (ADR-0053 §2).
  List<String> get targets => jsonDecodeListAs<String>(_reap['targets']);

  /// Extra protected command-line substrings, added to
  /// [defaultForeignOrphanProtected] (ADR-0053 §5).
  List<String> get protectedNames =>
      jsonDecodeListAs<String>(_reap['protected']);

  /// Encodes back to the `oka.yaml` payload map (identity).
  Map<String, dynamic> toJson() => value;
}
