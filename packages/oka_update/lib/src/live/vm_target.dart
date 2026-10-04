/// Native JIT targets over the VM service: stock `dart` VMs, `flutter run`
/// desktop apps (via DDS), and flutter devices. One class, two modes —
/// host (delta path is local) and device (delta is pushed over DevFS
/// first, then applied by URI).
library;

import 'dart:io' show File;

import 'spec.dart';
import 'target.dart';
import 'vm_service_wire.dart';

class VmJitTarget implements LivePatchTarget {
  VmJitTarget({
    required this.id,
    required this.wsUri,
    this.httpEndpoint,
    this.devfsName,
    this.devfsBaseOverride,
    this.applyVia,
    this.packagesPath,
  }) : _device = httpEndpoint != null && devfsName != null;

  @override
  final String id;
  @override
  final String kind = 'vm';

  /// VM-service WebSocket URI (`ws://.../ws`).
  final String wsUri;

  /// Device mode: the VM-service HTTP endpoint (DevFS push) and the DevFS
  /// name to write into.
  final String? httpEndpoint;
  final String? devfsName;

  /// Overrides the device-side base URI reported by `createDevFS` (some
  /// embedders report a URI the kernel reader cannot open).
  final String? devfsBaseOverride;

  /// Device-lane apply method; null = auto (`_reloadKernel`, then
  /// `reloadSources(rootLibUri)`). `reloadSources` skips straight to the
  /// public call — flutter desktop embedders die on a failed
  /// `_reloadKernel` before the fallback could run.
  final String? applyVia;

  /// Device-lane: local package config staged as `packagesUri`.
  final String? packagesPath;

  final bool _device;
  late VmServiceWire _wire;
  late String _devfsBase;
  late bool _connected = false;

  @override
  Future<void> connect() async {
    if (_connected) return;
    _wire = await VmServiceWire.connect(wsUri);
    if (_device) {
      final devfsName = this.devfsName;
      if (devfsName == null) {
        throw ArgumentError('device target needs `devfs`');
      }
      _devfsBase =
          devfsBaseOverride ?? await _wire.devfsCreate(devfsName);
    }
    _connected = true;
  }

  @override
  Future<ApplyOutcome> apply({
    required String unit,
    required String deltaPath,
    required int deltaBytes,
  }) async {
    final wire = _wire;
    if (!_device) {
      final sw = Stopwatch()..start();
      try {
        final isolate = await _isolateForApply();
        final report = await wire.reloadKernel(
            isolateId: isolate, kernelFilePath: deltaPath);
        sw.stop();
        // The report is the truth: success:false (or a rejected flag)
        // must fail the receipt, never pass silently (ADR-0034 G7).
        final success = report['success'];
        final ok = !(success is bool && !success);
        // G-RUN: a Flutter target repaints only when the reassemble
        // service extension runs after the reload. Best-effort — a
        // non-Flutter VM has no such extension and that is not a failure.
        var reassemble = 'skipped (reload failed)';
        if (ok) {
          try {
            await wire.flutterReassemble(isolateId: isolate);
            reassemble = 'ok';
          } on LiveWireException catch (e) {
            reassemble = 'absent (${e.message})';
          }
        }
        return ApplyOutcome(
            ok: ok,
            mode: 'reloadKernel',
            error: ok ? null : 'reload report: $report',
            wire: {
              'durationMs': sw.elapsedMilliseconds,
              'reassemble': reassemble,
              ...report,
            });
      } on LiveWireException catch (e) {
        return ApplyOutcome(ok: false, mode: 'reloadKernel', error: e.message);
      }
    }
    // Device mode: push the delta, then apply by device URI. `_reloadKernel`
    // first (proven on the embedder); the public `reloadSources(rootLibUri)`
    // as fallback — that is the exact shape flutter's own hot reload uses.
    final base = _devfsBase;
    final httpEndpoint = this.httpEndpoint!;
    final devfsName = this.devfsName!;
    final deviceUri = '${base.endsWith('/') ? base : '$base/'}$unit.delta.dill';
    final devicePath = Uri.parse(deviceUri).toFilePath();
    final bytes = await File(deltaPath).readAsBytes();
    await wire.devfsWrite(
        httpEndpoint: httpEndpoint,
        fsName: devfsName,
        deviceUri: deviceUri,
        bytes: bytes);
    final isolate = await _isolateForApply();
    // Flutter's own desktop hot reload stages the app's package file
    // alongside the kernel and passes both URIs; without `packagesUri`
    // the kernel-isolate path accepts the call and recompiles nothing.
    String? packagesUri;
    final packagesPath = this.packagesPath;
    if (packagesPath != null && File(packagesPath).existsSync()) {
      packagesUri =
          '${base.endsWith('/') ? base : '$base/'}package_config.json';
      await wire.devfsWrite(
          httpEndpoint: httpEndpoint,
          fsName: devfsName,
          deviceUri: packagesUri,
          bytes: File(packagesPath).readAsBytesSync());
    }
    // Flutter desktop embedders die on a failed `_reloadKernel`
    // (isolate_reload.cc CHECKs `delta_program != nullptr`) — when the
    // spec pins `applyVia`, honor it before any kernel attempt.
    if (applyVia != 'reloadSources') {
      try {
        await wire.reloadKernel(isolateId: isolate, kernelFilePath: devicePath);
        return ApplyOutcome(
            ok: true,
            mode: 'reloadKernel(devfs)',
            wire: {'deviceUri': deviceUri});
      } on LiveWireException {
        // fall through to the public reloadSources form
      }
    }
    try {
      final r = await wire.reloadSources(isolate,
          rootLibUri: deviceUri, packagesUri: packagesUri);
      final details =
          (r['details'] as Map? ?? const {}).cast<String, Object?>();
      final loaded = details['loadedLibraries'] ?? details['libraries'];
      final ok = !(r['success'] is bool && !(r['success'] as bool));
      return ApplyOutcome(
          ok: ok,
          mode: applyVia == 'reloadSources'
              ? 'reloadSources(rootLibUri)'
              : 'reloadKernel→reloadSources(rootLibUri)',
          wire: {
            'deviceUri': deviceUri,
            'packagesUri': ?packagesUri,
            ...details,
            if (loaded == null && details.isEmpty) 'detailsAbsent': true,
          });
    } on LiveWireException catch (e) {
      return ApplyOutcome(
          ok: false,
          mode: 'reloadSources(rootLibUri)',
          error: e.message,
          wire: {'deviceUri': deviceUri});
    }
  }

  @override
  Future<String> evaluate(ProbeSpec probe) async {
    final wire = _wire;
    final fragment = probe.library;
    if (fragment == null) {
      throw LiveWireException('vm probes need a `library` selector');
    }
    final loc = await wire.findLibrary(fragment);
    return wire.evaluate(
        isolateId: loc.isolateId,
        libraryId: loc.libraryId,
        expression: probe.expression);
  }

  Future<String> _isolateForApply() async {
    final vm = await _wire.rpc('getVM');
    final ids = ((vm['isolateIds'] ?? vm['isolates']) as List? ?? const [])
        .map((e) => (e as Map)['id'] as String)
        .toList();
    if (ids.isEmpty) throw LiveWireException('no isolates on $wsUri');
    return ids.first;
  }

  @override
  Future<void> close() => _wire.close();
}
