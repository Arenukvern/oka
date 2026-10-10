import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

/// A pattern that is neither [RegExp] nor [String]: JSON cannot carry it,
/// so encode must refuse it with a [SpecFormatException].
final class _ForeignPattern implements Pattern {
  const _ForeignPattern();

  @override
  Iterable<Match> allMatches(final String string, [final int start = 0]) =>
      const [];

  @override
  Match? matchAsPrefix(final String string, [final int start = 0]) => null;
}

void main() {
  const codec = SpecCodec();

  DesiredState everyKind() => DesiredState(
    readinessBudget: const Duration(seconds: 45),
    specs: [
      ComponentSpec(
        id: 'gateway',
        providerName: 'process',
        dependsOn: const ['api'],
        readiness: HandshakeLine(
          pattern: RegExp('^READY'),
          budget: const Duration(seconds: 9),
        ),
      ),
      const ComponentSpec(
        id: 'api',
        providerName: 'process',
        readiness: FilePresent('/tmp/api-ready'),
      ),
      ComponentSpec(
        id: 'scraper',
        providerName: 'process',
        readiness: LogPattern(
          RegExp('listening on [0-9]+'),
          budget: const Duration(seconds: 12),
        ),
        trigger: const WatchTrigger(
          roots: ['lib'],
          extensions: ['dart'],
          debounce: Duration(milliseconds: 250),
        ),
      ),
      const ComponentSpec(
        id: 'db',
        providerName: 'process',
        readiness: TcpConnect('127.0.0.1', 5432, budget: Duration(seconds: 3)),
      ),
      const ComponentSpec(
        id: 'all-of-it',
        providerName: 'process',
        readiness: ReadinessAll([
          TcpConnect('127.0.0.1', 5432),
          FilePresent('/tmp/db-ready'),
        ]),
      ),
      const ComponentSpec(
        id: 'nightly',
        providerName: 'process',
        policy: SupervisionPolicy(shape: SupervisionShape.job),
        trigger: IntervalTrigger(period: Duration(hours: 6)),
      ),
    ],
  );

  group('SpecCodec round-trip law', () {
    test('every spec keeps its revisionHash through decode(encode(d))', () {
      final desired = everyKind();
      final decoded = codec.decode(codec.encode(desired));

      expect(decoded.readinessBudget, const Duration(seconds: 45));
      expect(decoded.specs, hasLength(desired.specs.length));
      for (final spec in desired.specs) {
        expect(
          decoded.byId()[spec.id]!.revisionHash,
          spec.revisionHash,
          reason: 'spec "${spec.id}" must survive the round-trip',
        );
      }
    });

    test('readiness structure round-trips per kind', () {
      final decoded = codec.decode(codec.encode(everyKind()));
      final byId = decoded.byId();

      final handshake = byId['gateway']!.readiness! as HandshakeLine;
      expect(
        handshake.pattern,
        isA<RegExp>().having((final p) => p.pattern, 'pattern', '^READY'),
      );
      expect(handshake.budget, const Duration(seconds: 9));
      expect(handshake.parse, isNull);

      final file = byId['api']!.readiness! as FilePresent;
      expect(file.path, '/tmp/api-ready');
      expect(file.absenceIsLiveness, isTrue);
      expect(file.budget, isNull);

      final log = byId['scraper']!.readiness! as LogPattern;
      expect((log.pattern as RegExp).pattern, 'listening on [0-9]+');
      expect(log.budget, const Duration(seconds: 12));

      final tcp = byId['db']!.readiness! as TcpConnect;
      expect(tcp.host, '127.0.0.1');
      expect(tcp.port, 5432);
      expect(tcp.budget, const Duration(seconds: 3));

      final all = byId['all-of-it']!.readiness! as ReadinessAll;
      expect(all.conditions, hasLength(2));
      expect(all.conditions[0], isA<TcpConnect>());
      expect(all.conditions[1], isA<FilePresent>());

      final watch = byId['scraper']!.trigger as WatchTrigger;
      expect(watch.roots, ['lib']);
      expect(watch.extensions, ['dart']);
      expect(watch.debounce, const Duration(milliseconds: 250));

      final interval = byId['nightly']!.trigger as IntervalTrigger;
      expect(interval.period, const Duration(hours: 6));
    });

    test('RegExp patterns encode as their source strings', () {
      final json = codec.encode(
        DesiredState(
          specs: [
            ComponentSpec(
              id: 'api',
              providerName: 'process',
              readiness: LogPattern(RegExp(r'READY\.')),
            ),
          ],
        ),
      );
      expect(json, contains(r'"pattern": "READY\\."'));
    });

    test('decode(encode) of a decoded document is stable', () {
      final once = codec.decode(codec.encode(everyKind()));
      final twice = codec.decode(codec.encode(once));
      expect(
        [for (final spec in twice.specs) spec.revisionHash],
        [for (final spec in once.specs) spec.revisionHash],
      );
    });
  });

  group('SpecCodec decode of hand-written plans', () {
    const plan = '''
{
  "version": 1,
  "readinessBudgetMs": 15000,
  "specs": [
    {
      "id": "db",
      "provider": "process",
      "shape": "service",
      "readiness": {
        "kind": "tcpConnect", "host": "127.0.0.1", "port": 5432},
      "trigger": {"kind": "none"}
    },
    {
      "id": "api",
      "providerName": "process",
      "dependsOn": ["db"],
      "provides": ["api.port"],
      "readiness": {
        "kind": "handshakeLine",
        "pattern": "listening on (?<port>[0-9]+)",
        "budgetMs": 5000
      },
      "policy": {"maxRestarts": 5, "restartWindowS": 60},
      "trigger": {"kind": "watch", "roots": ["lib", "bin"]}
    },
    {
      "id": "nightly",
      "provider": "process",
      "shape": "job",
      "trigger": {"kind": "interval", "periodS": 3600}
    },
    {
      "id": "plain",
      "provider": "process",
      "shape": "job"
    }
  ]
}
''';

    test('produces expected typed values', () {
      final desired = codec.decode(plan);

      expect(desired.readinessBudget, const Duration(seconds: 15));
      expect(
        [for (final spec in desired.specs) spec.id],
        ['db', 'api', 'nightly', 'plain'],
      );

      final db = desired.byId()['db']!;
      expect(db.providerName, 'process');
      expect(db.policy.shape, SupervisionShape.service);
      expect(db.policy.maxRestarts, 3);
      expect(db.policy.restartWindow, const Duration(seconds: 120));
      expect(db.policy.revision, 1);
      expect(db.readiness, isA<TcpConnect>());
      expect(db.trigger, isA<NoTrigger>());
      expect(db.env, isEmpty);

      final api = desired.byId()['api']!;
      expect(api.providerName, 'process'); // via the providerName alias
      expect(api.dependsOn, ['db']);
      expect(api.provides, ['api.port']);
      final handshake = api.readiness! as HandshakeLine;
      expect(
        handshake.pattern,
        isA<RegExp>().having(
          (final p) => p.pattern,
          'pattern',
          'listening on (?<port>[0-9]+)',
        ),
      );
      expect(handshake.budget, const Duration(seconds: 5));
      // Closures never cross JSON; parsing stays Dart-side.
      expect(handshake.parse, isNull);
      expect(api.policy.maxRestarts, 5);
      expect(api.policy.restartWindow, const Duration(seconds: 60));
      expect(api.policy.revision, 1);
      final watch = api.trigger as WatchTrigger;
      expect(watch.roots, ['lib', 'bin']);
      expect(watch.extensions, isEmpty);
      expect(watch.debounce, const Duration(milliseconds: 500));

      final nightly = desired.byId()['nightly']!;
      expect(nightly.policy.shape, SupervisionShape.job);
      expect(
        (nightly.trigger as IntervalTrigger).period,
        const Duration(seconds: 3600),
      );
    });

    test('omitted trigger and readiness decode to null-safe defaults', () {
      final desired = codec.decode(plan);
      final plain = desired.byId()['plain']!;
      expect(plain.trigger, isA<NoTrigger>());
      expect(plain.readiness, isNull);
      expect(plain.dependsOn, isEmpty);
    });

    test('filePresent absenceIsLiveness defaults true, overrides false', () {
      final desired = codec.decode('''
{
  "version": 1,
  "specs": [
    {
      "id": "runner",
      "provider": "process",
      "readiness": {"kind": "filePresent", "path": "/tmp/lease"}
    },
    {
      "id": "kept",
      "provider": "process",
      "readiness": {
        "kind": "filePresent",
        "path": "/tmp/keep",
        "absenceIsLiveness": false
      }
    }
  ]
}
''');
      expect(
        (desired.byId()['runner']!.readiness! as FilePresent).absenceIsLiveness,
        isTrue,
      );
      expect(
        (desired.byId()['kept']!.readiness! as FilePresent).absenceIsLiveness,
        isFalse,
      );
    });

    test('handshakeLine with no pattern decodes to a null pattern', () {
      final desired = codec.decode('''
{
  "version": 1,
  "specs": [
    {
      "id": "api",
      "provider": "process",
      "readiness": {"kind": "handshakeLine"}
    }
  ]
}
''');
      final handshake = desired.byId()['api']!.readiness! as HandshakeLine;
      expect(handshake.pattern, isNull);
      expect(handshake.parse, isNull);
    });
  });

  group('SpecCodec decode errors', () {
    void expectRejected(final String json, {final String? containing}) {
      expect(
        () => codec.decode(json),
        throwsA(
          isA<SpecFormatException>().having(
            (final error) => '$error',
            'toString',
            contains(containing ?? 'invalid supervisor plan'),
          ),
        ),
        reason: 'should reject: $json',
      );
    }

    test('invalid JSON', () {
      expect(
        () => codec.decode('{not json'),
        throwsA(isA<SpecFormatException>()),
      );
    });

    test('top-level array', () {
      expectRejected('[]', containing: 'top level must be a JSON object');
    });

    test('wrong version', () {
      expectRejected(
        '{"version": 2, "specs": []}',
        containing: 'unsupported plan version 2',
      );
    });

    test('missing specs array', () {
      expectRejected('{"version": 1}', containing: '"specs" must be an array');
    });

    test('duplicate ids', () {
      expectRejected('''
{"version": 1, "specs": [
  {"id": "api", "provider": "p"},
  {"id": "api", "provider": "p"}
]}''', containing: 'duplicate spec id "api"');
    });

    test('empty id', () {
      expectRejected(
        '{"version": 1, "specs": [{"id": "", "provider": "p"}]}',
        containing: '"id" must be a non-empty string',
      );
    });

    test('empty provider', () {
      expectRejected(
        '{"version": 1, "specs": [{"id": "api", "provider": ""}]}',
        containing: '"provider" must be a non-empty string',
      );
    });

    test('unknown trigger kind', () {
      expectRejected('''
{"version": 1, "specs": [
  {"id": "api", "provider": "p", "trigger": {"kind": "cron"}}
]}''', containing: 'unknown trigger kind "cron"');
    });

    test('watch with empty roots', () {
      expectRejected('''
{"version": 1, "specs": [
  {"id": "api", "provider": "p",
   "trigger": {"kind": "watch", "roots": []}}
]}''', containing: 'non-empty "roots"');
    });

    test('interval with periodS 0', () {
      expectRejected('''
{"version": 1, "specs": [
  {"id": "api", "provider": "p",
   "trigger": {"kind": "interval", "periodS": 0}}
]}''', containing: 'positive "periodS"');
    });

    test('unknown readiness kind', () {
      expectRejected('''
{"version": 1, "specs": [
  {"id": "api", "provider": "p",
   "readiness": {"kind": "magic"}}
]}''', containing: 'unknown readiness kind "magic"');
    });

    test('tcpConnect bad port (0 and 70000)', () {
      for (final port in const [0, 70000]) {
        expectRejected('''
{"version": 1, "specs": [
  {"id": "api", "provider": "p",
   "readiness": {"kind": "tcpConnect", "host": "localhost", "port": $port}}
]}''', containing: '"port" in 1..65535');
      }
    });

    test('logPattern missing pattern', () {
      expectRejected('''
{"version": 1, "specs": [
  {"id": "api", "provider": "p",
   "readiness": {"kind": "logPattern"}}
]}''', containing: '"pattern" must be a non-empty string');
    });

    test('env with non-string value', () {
      expectRejected('''
{"version": 1, "specs": [
  {"id": "api", "provider": "p", "env": {"PORT": 8080}}
]}''', containing: 'env["PORT"] must be a string');
    });

    test('readinessBudgetMs non-int', () {
      expectRejected(
        '{"version": 1, "readinessBudgetMs": "30000", "specs": []}',
        containing: '"readinessBudgetMs" must be an integer',
      );
    });

    test('dependsOn with non-string entry', () {
      expectRejected('''
{"version": 1, "specs": [
  {"id": "api", "provider": "p", "dependsOn": ["db", 3]}
]}''', containing: '"dependsOn" entries must be strings');
    });
  });

  group('SpecCodec encode errors', () {
    test('a pattern that is neither RegExp nor String is refused', () {
      const desired = DesiredState(
        specs: [
          ComponentSpec(
            id: 'api',
            providerName: 'process',
            readiness: HandshakeLine(pattern: _ForeignPattern()),
          ),
        ],
      );
      expect(() => codec.encode(desired), throwsA(isA<SpecFormatException>()));
    });

    test('String patterns encode as themselves', () {
      final json = codec.encode(
        const DesiredState(
          specs: [
            ComponentSpec(
              id: 'api',
              providerName: 'process',
              readiness: HandshakeLine(pattern: 'READY'),
            ),
          ],
        ),
      );
      expect(json, contains('"pattern": "READY"'));
    });
  });
}
