import 'dart:async';
import 'dart:convert';

import 'package:universal_automation_interface/universal_automation_interface.dart'
    show SurfaceActionDescriptor;

import 'events.dart';
import 'receipt.dart';
import 'session.dart';
import 'spec.dart';
import 'target.dart';
import 'verify.dart';
import 'watcher.dart';

/// The live-update agent surface (ADR-0036 Tier 2): the interactive agent
/// loop declared as actions, not shell one-liners.
///
/// [liveVerbCatalog] carries three verbs — `oka.live.patch`,
/// `oka.live.watch`, `oka.live.verify` — as pure data:
/// [LiveVerb.descriptor] is a typed `SurfaceActionDescriptor`
/// (`universal_automation_interface`), and [LiveVerb.run] dispatches
/// into the same session API the gates use. Embeddings provide the [LiveVerbHost]
/// (toolchain + root); transports (UA dispatch, a future `oka ship`
/// daemon) carry the descriptor and argument maps — no new server.
///
/// What a verb embedding provides: the compiled-toolchain seam and the
/// root the spec's relative paths resolve against.
abstract interface class LiveVerbHost {
  UnitDeltaCompiler get compile;
  String get root;
  Map<String, LivePatchTarget> get targetOverrides;
  void Function(LivePatchEvent event)? get onEvent;
}

/// One declared action: pure descriptor data plus its dispatch.
final class LiveVerb {
  const LiveVerb({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.run,
  });

  /// Catalog-unique, dotted name (the app-owned namespace convention).
  final String name;
  final String description;

  /// JSON-Schema (subset) the argument map must satisfy.
  final Map<String, Object?> inputSchema;

  /// Argument map in, receipt JSON out.
  final Future<Map<String, Object?>> Function(
          Map<String, Object?> args, LiveVerbHost host)
      run;

  /// The typed UA catalog entry — pure data, carryable by any transport.
  SurfaceActionDescriptor get descriptor =>
      SurfaceActionDescriptor(name: name, description: description, inputSchema: inputSchema);
}

/// The three declared live-update verbs.
final List<LiveVerb> liveVerbCatalog = [
  LiveVerb(
    name: 'oka.live.patch',
    description:
        'Apply one live revision to every declared target and verify the '
        'probes. Returns the receipt JSON (ok, per-target mode, probe '
        'flips, continuity holds). Never restarts a target.',
    inputSchema: {
      'type': 'object',
      'required': ['spec'],
      'properties': {
        'spec': {
          'type': 'object',
          'description': 'A LivePatchSpec JSON: revision, unit, patches '
              '(file/find/replace), targets, probes.',
        },
      },
    },
    run: (args, host) async {
      final spec = _specOf(args);
      final receipt = await runLivePatch(
        spec,
        compile: host.compile,
        root: host.root,
        targetOverrides: host.targetOverrides,
        onEvent: host.onEvent,
      );
      return receipt.toJson();
    },
  ),
  LiveVerb(
    name: 'oka.live.watch',
    description:
        'The editor-save flow: compile the already-changed file as the unit '
        'delta and apply it, or start the watcher and return its first '
        'receipt. Silent on success; refusals land in the receipt.',
    inputSchema: {
      'type': 'object',
      'required': ['spec'],
      'properties': {
        'spec': {'type': 'object'},
        'changedFile': {
          'type': 'string',
          'description':
              'Absolute path of the file the user already saved; when set, '
              'exactly that file compiles as the delta (no spec patches).',
        },
        'watch': {
          'type': 'boolean',
          'description':
              'When true, run LiveWatcher until the first receipt, then '
              'stop. Default false (single applyChange).',
        },
      },
    },
    run: (args, host) async {
      final spec = _specOf(args);
      final changedFile = args['changedFile'] as String?;
      if (changedFile != null) {
        final receipt = await applyChange(
          spec,
          changedFile: changedFile,
          compile: host.compile,
          root: host.root,
          targetOverrides: host.targetOverrides,
          onEvent: host.onEvent,
        );
        return receipt.toJson();
      }
      if (args['watch'] == true) {
        final receipt = await _watchOnce(spec, host);
        return receipt.toJson();
      }
      throw ArgumentError(
          "oka.live.watch needs 'changedFile' or watch: true");
    },
  ),
  LiveVerb(
    name: 'oka.live.verify',
    description:
        'Pre-flight: connect to every declared target, capture the probe '
        'values, close. No patch, no compile. Receipt targets are ok only '
        'when reachable and every probe evaluates.',
    inputSchema: {
      'type': 'object',
      'required': ['spec'],
      'properties': {
        'spec': {'type': 'object'},
      },
    },
    run: (args, host) async {
      final receipt = await verifyLiveTargets(
        _specOf(args),
        root: host.root,
        targetOverrides: host.targetOverrides,
        onEvent: host.onEvent,
      );
      return receipt.toJson();
    },
  ),
];

/// Dispatches one declared verb by name. Throws [ArgumentError] for an
/// unknown name — transports surface that as their own error shape.
Future<Map<String, Object?>> runLiveVerb(
  String name,
  Map<String, Object?> args,
  LiveVerbHost host,
) {
  final verb = liveVerbCatalog.where((v) => v.name == name).toList();
  if (verb.isEmpty) {
    throw ArgumentError('unknown live verb: $name '
        '(known: ${liveVerbCatalog.map((v) => v.name).join(", ")})');
  }
  return verb.single.run(args, host);
}

/// The descriptor list, transport-ready (UA action catalogs, MCP tool
/// listings, `oka ship` manifests — the shape is identical everywhere).
List<SurfaceActionDescriptor> get liveVerbDescriptors =>
    [for (final v in liveVerbCatalog) v.descriptor];

LivePatchSpec _specOf(Map<String, Object?> args) {
  final json = args['spec'];
  if (json is Map) {
    return LivePatchSpec.fromJson(json.cast<String, dynamic>());
  }
  if (json is String) {
    return LivePatchSpec.fromJson(
        (jsonDecode(json) as Map).cast<String, dynamic>());
  }
  throw ArgumentError("oka.live.* needs a 'spec' (object or JSON string)");
}

/// Starts [LiveWatcher], resolves with its first receipt, stops it. The
/// agent loop re-invokes the verb per save; nothing runs unbounded.
Future<LivePatchReceipt> _watchOnce(LivePatchSpec spec, LiveVerbHost host) {
  final completer = Completer<LivePatchReceipt>();
  final watcher = LiveWatcher(
    unit: spec.unit,
    files: [
      for (final p in spec.patches) p.file,
    ],
    revision: spec.revision,
    targets: spec.targets,
    probes: spec.probes,
    compile: host.compile,
    root: host.root,
    targetOverrides: host.targetOverrides,
    onEvent: host.onEvent,
  )..start();
  watcher.receipts.listen(
    (receipt) {
      if (!completer.isCompleted) completer.complete(receipt);
    },
    onError: (Object e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    },
  );
  return completer.future.whenComplete(watcher.stop);
}
