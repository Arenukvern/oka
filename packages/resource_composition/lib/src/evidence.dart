/// Evidence sinks: bounded, policy-controlled lifecycle records
/// (ADR-0026 decision 5 / plan R1).
///
/// Day-one surface only: lifecycle events plus bounded output taps.
/// Retention, redaction, and crash-artifact policy frameworks are deferred
/// until a second consumer demands them; evidence is diagnostic and never
/// authority to terminate a process.
library;

import 'dart:io';

import 'events.dart';

/// Receives structured lifecycle events.
///
/// A sink is a seam, not a function; other members (retention policy) are
/// deferred, not absent by design.
// ignore: one_member_abstracts
abstract interface class EvidenceSink {
  void add(final LifecycleEvent event);
}

/// In-memory collector — the default for tests and short-lived runs.
final class CollectingEvidenceSink implements EvidenceSink {
  final events = <LifecycleEvent>[];

  @override
  void add(final LifecycleEvent event) => events.add(event);
}

/// Append-only JSONL sink; one [LifecycleEvent.toJsonLine] per row.
final class JsonlEvidenceSink implements EvidenceSink {
  JsonlEvidenceSink(final String path)
    : _sink = File(path).openWrite(mode: FileMode.append);

  final IOSink _sink;

  @override
  void add(final LifecycleEvent event) => _sink.writeln(event.toJsonLine());

  /// Flushes and closes; call on run teardown.
  Future<void> close() => _sink.close();
}
