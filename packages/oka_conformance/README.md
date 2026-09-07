# oka_conformance

Shared publish-target conformance suite for [oka](https://github.com/Arenukvern/oka)
target packages (ADR-0014) — the `universal_storage_conformance` pattern
applied to oka publishing.

Any `PublishTarget` package (`oka_play`, `oka_huawei`, …) asserts the three
publishing laws from its tests with one call:

```dart
import 'package:oka_conformance/oka_conformance.dart';

test('publish-play conforms (ADR-0014)', () async {
  await expectPublishConformance(
    const PlayPublishTarget(),
    ctx,
    sourcePaths: [p.absolute('lib/src')],
  );
});
```

Plus helpers:

- `expectPlanShape` / `expectPlanDescribes` — dry-run plan-shape assertions.
- `expectNoSecretMaterial` / `expectStateRedacted` — redaction assertions
  over any dumped text or `PipelineState`.
- `FakeHttpTransport` — scripted, recording, offline `http.Client` for the
  real-run tests (throws on unexpected requests; `assertNoRequests()` for
  the dry-run zero-HTTP law).

See the [docs](https://docs.page/arenukvern/oka) and the
[design decisions](https://github.com/Arenukvern/oka/tree/main/docs/decisions).
