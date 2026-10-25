/// Run receipts for the oka verify lane (ADR-0048): a verification claim
/// that names its own revision, so a stale or partially-applied state can
/// never masquerade as a green run.
library;

import 'dart:convert';
import 'dart:io';

/// The receipt of one verify run.
final class VerifyReceipt {
  VerifyReceipt({
    required this.revision,
    required this.sdkVersion,
    required this.packageName,
    required this.changedFiles,
    required this.selectedSuites,
    required this.rebuiltSuites,
    required this.cacheHits,
    required this.pass,
    required this.graphMs,
    required this.rebuildMs,
    required this.runMs,
    this.rebuildError,
    this.staleSuites = const <String>[],
    this.refusedFlutterSuites = const <String>[],
    this.uncoveredChanges = const <String>[],
    this.broadenReason,
    this.outputTruncated = false,
    this.timedOut = false,
  });

  /// The git revision the run was made against.
  final String revision;

  /// The SDK that compiled and ran the suites.
  final String sdkVersion;

  /// The package that was verified.
  final String packageName;

  /// The changed files the selection was derived from.
  final List<String> changedFiles;

  /// The suites the run selected.
  final List<String> selectedSuites;

  /// The suites whose kernel was rebuilt.
  final List<String> rebuiltSuites;

  /// The suites whose cached kernel was still valid.
  final int cacheHits;

  /// Whether the run passed.
  final bool pass;

  /// The graph phase, in milliseconds.
  final int graphMs;

  /// The kernel rebuild phase, in milliseconds.
  final int rebuildMs;

  /// The suite run phase, in milliseconds.
  final int runMs;

  /// The compiler output of the first failing suite, when the run failed
  /// before running anything.
  final String? rebuildError;

  /// The suites whose cached kernel was stale.
  final List<String> staleSuites;

  /// The widget suites the lane refused (they need `flutter_tester`).
  final List<String> refusedFlutterSuites;

  /// The changed files whose effect on the suite set was unknown.
  final List<String> uncoveredChanges;

  /// Why the run was widened, or null when it was not.
  final String? broadenReason;

  /// True when the runner's output hit the echo budget.
  final bool outputTruncated;

  /// True when the runner hit the run deadline and was stopped.
  final bool timedOut;

  /// The receipt as a JSON map.
  Map<String, Object?> toJson() => {
    'tool': 'oka_verify',
    'revision': revision,
    'sdkVersion': sdkVersion,
    'package': packageName,
    'changedFiles': changedFiles,
    'selectedSuites': selectedSuites,
    'rebuiltSuites': rebuiltSuites,
    'staleSuites': staleSuites,
    'cacheHits': cacheHits,
    'pass': pass,
    'refusedFlutterSuites': refusedFlutterSuites,
    'uncoveredChanges': uncoveredChanges,
    if (broadenReason != null) 'broadenReason': broadenReason,
    'outputTruncated': outputTruncated,
    'timedOut': timedOut,
    'timingsMs': {'graph': graphMs, 'rebuild': rebuildMs, 'run': runMs},
    if (rebuildError != null) 'rebuildError': rebuildError,
  };

  /// The receipt as indented JSON.
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Writes the receipt to [path].
  void write(String path) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(encode());
  }
}
