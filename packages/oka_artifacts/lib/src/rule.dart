/// Storage strategies per artifact (ADR-0043 decisions 2–3). Closed
/// types: [SnapshotOnly] for classes where deltas never pay; [DeltaChain]
/// where the snapshot cadence emerges from the measured delta ratio.
library;

/// How the store may represent a new revision of one artifact.
sealed class StorageStrategy {
  const StorageStrategy();

  /// Manifest echo, so chains stay self-describing.
  Map<String, Object?> toJson();

  static StorageStrategy fromJson(final Map<String, Object?> json) =>
      switch (json['kind']) {
        'snapshotOnly' => const SnapshotOnly(),
        'deltaChain' => DeltaChain(
          rolloverWhen: DeltaRatio(
            over:
                (json['rolloverRatio'] as num?)?.toDouble() ??
                DeltaRatio.defaultThreshold,
          ),
          orEvery: json['orEvery'] as int? ?? DeltaChain.defaultOrEvery,
          maxChainDepth:
              json['maxChainDepth'] as int? ?? DeltaChain.defaultMaxDepth,
        ),
        final other => throw ArgumentError('unknown storage strategy "$other"'),
      };
}

/// Full snapshots only; dedup by content hash still applies.
final class SnapshotOnly extends StorageStrategy {
  const SnapshotOnly();

  @override
  Map<String, Object?> toJson() => const {'kind': 'snapshotOnly'};
}

/// Append deltas against the materialized head while they pay;
/// otherwise take a fresh snapshot. A delta "stops paying" when
/// [DeltaRatio] fires, when [maxChainDepth] is reached, or after
/// [orEvery] revisions since the last snapshot.
final class DeltaChain extends StorageStrategy {
  const DeltaChain({
    this.rolloverWhen = const DeltaRatio(),
    this.orEvery = defaultOrEvery,
    this.maxChainDepth = defaultMaxDepth,
  });

  static const int defaultOrEvery = 20;
  static const int defaultMaxDepth = 8;

  /// The economics rule: a delta that costs more than this fraction of
  /// the full content takes a snapshot instead.
  final DeltaRatio rolloverWhen;

  /// Hard snapshot cadence regardless of ratios.
  final int orEvery;

  /// Materialization-cost bound: at most this many deltas ever chain
  /// before a snapshot resets the walk.
  final int maxChainDepth;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'deltaChain',
    'rolloverRatio': rolloverWhen.over,
    'orEvery': orEvery,
    'maxChainDepth': maxChainDepth,
  };
}

/// Delta pays while `deltaSize / fullSize <= over`.
final class DeltaRatio {
  const DeltaRatio({this.over = defaultThreshold});

  static const double defaultThreshold = 0.35;

  final double over;
}
