/// Declarative live-patch spec: the whole run (what changes, where it
/// applies, what must be observed) is data — constructible in code or
/// loaded from JSON. Nothing about a target is discovered implicitly; the
/// spec names every wire.
library;

import 'dart:convert';
import 'dart:io';

/// A source rewrite applied before the delta is compiled.
class PatchEdit {
  const PatchEdit({required this.file, required this.find, required this.replace});

  factory PatchEdit.fromJson(Map<String, dynamic> j) => PatchEdit(
        file: j['file'] as String,
        find: j['find'] as String,
        replace: j['replace'] as String,
      );

  /// Path of the file to rewrite (relative to the app root when loaded
  /// from a spec file, absolute otherwise).
  final String file;
  final String find;
  final String replace;

  Map<String, Object?> toJson() =>
      {'file': file, 'find': find, 'replace': replace};

}

/// How to reach one running program. Kind is the only branch; everything
/// else is a plain field.
///
/// - `vm`    — native JIT (stock `dart`, `flutter run` DDS on desktop or a
///             device). Fields: `ws`; for a device also `http` (VM-service
///             HTTP endpoint) and `devfs` (DevFS name) so the delta is
///             pushed to the device before apply.
/// - `web`   — a DDC/DDK web app served by dwds. Fields: `ws` (the dwds
///             debug-service URI, same VM-service wire).
/// - `staged`— AOT/restart lane: unit part artifacts are staged next to the
///             base snapshot; applied by the runtime's deferred loader at
///             next load. Fields: `dir`, `base` (base artifact name).
class TargetSpec {
  const TargetSpec({
    required this.kind,
    required this.id,
    this.ws,
    this.http,
    this.devfs,
    this.dir,
    this.base,
    this.pidFile,
    this.signal,
    this.unitArtifact,
    this.cdp,
    this.settleMs = 0,
    this.applyVia,
    this.packages,
  });

  /// Local/remote VM-service target on 127.0.0.1:[port] (stock dart VM,
  /// flutter desktop via DDS, or `dart run` servers).
  const TargetSpec.vmPort(int port, {this.id = 'vm', this.devfs})
      : kind = 'vm',
        ws = 'ws://127.0.0.1:$port/ws',
        http = null,
        base = null,
        pidFile = null,
        signal = null,
        unitArtifact = null,
        cdp = null,
        settleMs = 0,
        applyVia = null,
        packages = null,
        dir = null;

  factory TargetSpec.fromJson(Map<String, dynamic> j) => TargetSpec(
        kind: j['kind'] as String,
        id: j['id'] as String,
        ws: j['ws'] as String?,
        http: j['http'] as String?,
        devfs: j['devfs'] as String?,
        dir: j['dir'] as String?,
        base: j['base'] as String?,
        pidFile: j['pidFile'] as String?,
        signal: j['signal'] as String?,
        unitArtifact: j['unitArtifact'] as String?,
        cdp: j['cdp'] as String?,
        settleMs: j['settleMs'] as int? ?? 0,
        applyVia: j['applyVia'] as String?,
        packages: j['packages'] as String?,
      );

  final String kind;
  final String id;
  final String? ws;
  final String? http;
  final String? devfs;

  /// Staged lane only: directory holding the app artifacts.
  final String? dir;
  final String? base;

  /// Web lane: declarative recompile trigger — send [signal] to the pid in
  /// [pidFile] before applying (`flutter run` maps SIGUSR1 to hot reload).
  final String? pidFile;
  final String? signal;

  /// Staged lane: patched unit artifact to stage (AOT part).
  final String? unitArtifact;

  /// Web lane: browser (CDP) page WebSocket URL for page-level probes.
  final String? cdp;

  /// Milliseconds to wait after a successful apply before verifying — for
  /// wires whose apply returns before the program has fully settled.
  final int settleMs;

  /// Device-lane apply method. Null = auto (`_reloadKernel` first, then the
  /// `reloadSources(rootLibUri)` fallback). `reloadSources` = go straight
  /// to the public `reloadSources(rootLibUri)` — required for flutter
  /// desktop embedders, where a failed `_reloadKernel` tears the app down
  /// (isolate_reload.cc: `delta_program != nullptr`) before the fallback
  /// can fire.
  final String? applyVia;

  /// Device-lane: local path of the app's package config, staged into the
  /// DevFS and passed as `reloadSources`' `packagesUri` (flutter's own
  /// hot-reload shape; without it the desktop kernel path recompiles
  /// nothing).
  final String? packages;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'id': id,
        if (ws != null) 'ws': ws,
        if (http != null) 'http': http,
        if (devfs != null) 'devfs': devfs,
        if (dir != null) 'dir': dir,
        if (base != null) 'base': base,
        if (pidFile != null) 'pidFile': pidFile,
        if (signal != null) 'signal': signal,
        if (unitArtifact != null) 'unitArtifact': unitArtifact,
        if (cdp != null) 'cdp': cdp,
        if (settleMs != 0) 'settleMs': settleMs,
        if (applyVia != null) 'applyVia': applyVia,
        if (packages != null) 'packages': packages,
      };

}

/// An observation that must hold or flip after the apply.
///
/// - `expect` set: the value must CONTAIN it after the apply (the patch
///   took effect).
/// - `hold: true`: the value must be IDENTICAL before and after — evidence
///   the process was never restarted.
class ProbeSpec {
  const ProbeSpec({
    required this.expression,
    this.library,
    this.expect,
    this.hold = false,
    this.webExpression,
  });

  factory ProbeSpec.fromJson(Map<String, dynamic> j) => ProbeSpec(
        expression: j['expression'] as String,
        library: j['library'] as String?,
        expect: j['expect'] as String?,
        hold: j['hold'] as bool? ?? false,
        webExpression: j['webExpression'] as String?,
      );

  final String expression;

  /// Library selector: a fragment matched against the running isolate's
  /// library URIs (same discipline the kernel gates use).
  final String? library;
  final String? expect;
  final bool hold;

  /// Optional web-target dialect: a JS expression evaluated in the page via
  /// the browser wire (CDP `Runtime.evaluate`), for when the dwds DDK
  /// `evaluate` is unavailable. DDK libraries expose their top-levels
  /// synchronously: `dartDevEmbedder.importLibrary('package:...').member`.
  final String? webExpression;

  Map<String, Object?> toJson() => {
        'expression': expression,
        if (library != null) 'library': library,
        if (expect != null) 'expect': expect,
        if (hold) 'hold': true,
        if (webExpression != null) 'webExpression': webExpression,
      };

}

/// The whole declarative run.
class LivePatchSpec {
  const LivePatchSpec({
    required this.revision,
    required this.unit,
    required this.patches,
    required this.targets,
    required this.probes,
    this.baseManifest,
    this.nextManifest,
  });

  factory LivePatchSpec.fromJson(Map<String, dynamic> j) => LivePatchSpec(
        revision: j['revision'] as String,
        unit: j['unit'] as String,
        patches: [
          for (final p in (j['patches'] as List).cast<Map<String, dynamic>>())
            PatchEdit.fromJson(p),
        ],
        targets: [
          for (final t in (j['targets'] as List).cast<Map<String, dynamic>>())
            TargetSpec.fromJson(t),
        ],
        probes: [
          for (final p in (j['probes'] as List).cast<Map<String, dynamic>>())
            ProbeSpec.fromJson(p),
        ],
        baseManifest: j['baseManifest'] as String?,
        nextManifest: j['nextManifest'] as String?,
      );

  final String revision;
  final String unit;
  final List<PatchEdit> patches;
  final List<TargetSpec> targets;
  final List<ProbeSpec> probes;

  /// Optional ADR-0031 revision manifests; when both are given the session
  /// checks eligibility ([planRevisions]) before touching anything.
  final String? baseManifest;
  final String? nextManifest;

  Map<String, Object?> toJson() => {
        'revision': revision,
        'unit': unit,
        'patches': [for (final p in patches) p.toJson()],
        'targets': [for (final t in targets) t.toJson()],
        'probes': [for (final p in probes) p.toJson()],
        if (baseManifest != null) 'baseManifest': baseManifest,
        if (nextManifest != null) 'nextManifest': nextManifest,
      };


  /// Loads a spec from a JSON file. Patch `file` paths resolve relative to
  /// the spec's directory.
  static Future<LivePatchSpec> load(String path) async {
    final file = File(path);
    final spec = LivePatchSpec.fromJson(
        (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>());
    return spec;
  }
}
