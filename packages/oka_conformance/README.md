# oka_conformance

Shared publish-target conformance suite for
[oka](https://github.com/Arenukvern/oka) — the
`universal_storage_conformance` pattern applied to oka publishing (ADR-0014).

Any oka `PublishTarget` package (`oka_play`, `oka_huawei`, and yours) must
uphold the **three publishing laws**. This package turns them into a
reusable, fully offline test harness:

1. **Dry-run without credentials succeeds** and produces a `PublishPlan`
   describing exactly what a real run would do (endpoint, track, artifact,
   metadata — credential *paths* only, rendered redacted).
2. **No stdin, ever** — asserted over the target package's Dart sources.
3. **No secret values in state, logs, or events** — only credential refs,
   booleans, numbers, plans, and path/id strings; every ref renders
   redacted.

A complete, compiling walkthrough for your own target lives in
[`example/publish_conformance_example.dart`](example/publish_conformance_example.dart).

## Quickstart: assert an existing target

From your target package's tests, one call:

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

`expectPublishConformance` throws `PublishConformanceException` with a
human-readable violation list when any law fails — and never touches the
network, credentials, or stdin itself.

## Make your own target conform (numbered)

Writing a new store/distribution target for oka:

1. **Extend `PublishTarget`** (oka_core): implement `name`, `description`,
   `endpoint`, `track`, `artifactId`, `metadata`, `credentialRefs`,
   `publishSteps` (stages the publish artifact), and `uploadStep` (the
   real tail — never invoked while `dryRun` is true).
2. **Add the dev dependency**: `oka_conformance: ^0.1.6`.
3. **Assert the suite** from `test/`:
   `await expectPublishConformance(target, ctx, sourcePaths:
   [p.absolute('lib/src')]);` — law 1 (dry-run chain compiles, validates,
   runs on an empty state, and yields a plan), law 2 (no `stdin` /
   `readLineSync` in your sources), law 3 (state holds only refs,
   booleans, numbers, plans, and path/id strings, all redacted).
4. **Test the real upload offline**: script every request with
   `FakeHttpTransport` (below) — an unexpected request throws, so tests
   cannot leak onto the network.
5. **Pin the plan shape**: `expectPlanShape` / `expectPlanDescribes` so
   your documented dry-run output cannot drift from reality.
6. **Document the failure candidates**: a failed credential resolution
   names every policy tier tried plus the fix — mirror that in your
   README's failure table.

## The helpers

| Helper | What it asserts |
|---|---|
| `expectPublishConformance` | All three laws in one throwing call; scans `sourcePaths` for stdin usage |
| `auditPublishConformance` | The same laws as a violation list (empty = conforming) — for tools and custom harnesses |
| `expectPlanShape` | The dry-run plan names the endpoint/track/artifact/metadata/credentials a real run would use (`exactMetadata: true` requires the exact map; `credentials:` matches refs in order) |
| `expectPlanDescribes` | `plan.describeLines()` contains every listed fragment — pin your documented output |
| `expectNoSecretMaterial` | Dumped text (logs, plans, request dumps) carries no credential paths or forbidden patterns |
| `expectStateRedacted` | A `PipelineState` dump holds only allowed value types, redacted |
| `FakeHttpTransport` | Scripted, recording `http.Client` — replays canned replies in order, throws on unexpected requests, `assertNoRequests()` proves zero HTTP |

### Pinning the plan shape (the documented output law)

```dart
final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
expectPlanShape(
  plan,
  target: 'publish-play',
  track: 'internal',
  artifactId: 'aab-path',
  dryRun: true,
  metadata: const {'packageName': 'dev.example.app'},
);
expectPlanDescribes(plan, [
  'target: publish-play (dry run — nothing was uploaded)',
  'credential: CredentialRef(play/service-account-json → [redacted])',
]);
```

### Scripting the real run offline

```dart
final transport = FakeHttpTransport()
  ..routeJsonAlways(
    url: 'https://oauth2.googleapis.com/token',
    json: {'access_token': 'test-token', 'expires_in': 3600},
  );
// … hand the transport to the step under test (injectable http client),
// then assert the exact conversation:
expect(transport.requests.map((final r) => r.url.toString()), [
  'https://oauth2.googleapis.com/token',
  'https://androidpublisher.googleapis.com/…',
]);
```

## FAQ

**Does the suite hit the network?**
Never. Dry-run chains are asserted zero-HTTP (`assertNoRequests()` with a
canary transport), and real-run tests run against `FakeHttpTransport`,
which throws on any unscripted request. Tests are offline by construction.

**Do I need credentials to run the conformance suite?**
No — that is law 1. The dry-run chain must compile, validate, and produce
a plan on an *empty* state: no credential files, no env vars, no stdin.

**Does it execute my upload step?**
No. `auditPublishConformance` runs only dry-run pipelines (where oka_core
substitutes the plan step for the upload step); a real-mode target is only
compiled and validated, never executed.

**What counts as "secret-ish"?**
`secretishKeyPatterns` (exported) — key names matching password/token/
secret/credential patterns are rejected in state, and `isSecretishKey` is
the one-key check. Values are allowed only in the types law 3 lists.

**Can I use it for non-store targets?**
The suite targets `PublishTarget` contracts (publishing laws). Plain
`Target`s compose through `oka_core`'s `Pipeline.validate` /
`describeTarget` directly; reuse `expectNoSecretMaterial` /
`expectStateRedacted` for any state-dumping surface.

**My target legitimately ships a path string in state — is that allowed?**
Yes. Law 3 allows refs, booleans, numbers, plans, and plain path/id
strings. What is forbidden is secret *values* and secret-ish *keys*.

See the [docs](https://docs.page/arenukvern/oka) and the
[design decisions](https://github.com/Arenukvern/oka/tree/main/docs/decisions)
(ADR-0014 publishing laws and the three-tier secrets model).
