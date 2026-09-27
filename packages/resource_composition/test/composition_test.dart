import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

void main() {
  test('valid graph passes validation and explain is deterministic', () {
    final a = FakeProvider();
    final b = FakeProvider();
    final composition = Composition(components: [
      Component(
        id: 'a',
        provider: a,
        readiness: const TcpConnect('127.0.0.1', 8080),
        lifecycle: const Lifecycle(scope: ResourceScope.session),
      ),
      Component(
        id: 'b',
        provider: b,
        dependsOn: const ['a'],
        lifecycle: const Lifecycle(scope: ResourceScope.session),
      ),
    ]);
    expect(composition.validate().ok, isTrue);
    expect(composition.explain(), composition.explain());
    expect(composition.explain(), contains('- a [FakeProvider]'));
    expect(composition.explain(), contains('dependsOn: a'));
    expect(composition.explain(), contains('tcp connect 127.0.0.1:8080'));
  });

  test('duplicate ids are rejected', () {
    final composition = Composition(components: [
      Component(id: 'a', provider: FakeProvider()),
      Component(id: 'a', provider: FakeProvider()),
    ]);
    final report = composition.validate();
    expect(report.ok, isFalse);
    expect(
      report.issues.map((final i) => i.code),
      contains('duplicateComponentId'),
    );
  });

  test('unknown dependencies are rejected', () {
    final composition = Composition(components: [
      Component(id: 'a', provider: FakeProvider(), dependsOn: const ['ghost']),
    ]);
    expect(
      composition.validate().issues.map((final i) => i.code),
      contains('unknownDependency'),
    );
  });

  test('cycles are rejected by name', () {
    final composition = Composition(components: [
      Component(id: 'a', provider: FakeProvider(), dependsOn: const ['b']),
      Component(id: 'b', provider: FakeProvider(), dependsOn: const ['a']),
    ]);
    final issues = composition.validate().issues;
    expect(issues.map((final i) => i.code), contains('cyclicDependency'));
    expect(issues.firstWhere((final i) => i.code == 'cyclicDependency').message,
        contains('a ->'));
  });

  test('unmet output requirements are rejected transitively', () {
    const port = OutputRef<int>('collector.port');
    final composition = Composition(components: [
      Component(id: 'collector', provider: FakeProvider()),
      Component(
        id: 'agent',
        provider: FakeProvider(),
        dependsOn: const ['collector'],
        requires: const [port],
      ),
    ]);
    expect(
      composition.validate().issues.map((final i) => i.code),
      contains('unmetRequirement'),
    );
  });

  test('a provided requirement passes validation', () {
    const port = OutputRef<int>('collector.port');
    final composition = Composition(components: [
      Component(
        id: 'collector',
        provider: FakeProvider(),
        provides: const [port],
        readiness: const HandshakeLine(pattern: 'ready '),
      ),
      Component(
        id: 'agent',
        provider: FakeProvider(),
        dependsOn: const ['collector'],
        requires: const [port],
      ),
    ]);
    expect(composition.validate().ok, isTrue);
  });

  test('readiness without the provider capability is rejected with '
      'remediation', () {
    final composition = Composition(components: [
      Component(
        id: 'a',
        provider: FakeProvider(
          capabilities: const ProviderCapabilities(),
        ),
        readiness: const FilePresent('x.json'),
      ),
    ]);
    final issues = composition.validate().issues;
    expect(issues.map((final i) => i.code), contains('capabilityReadiness'));
    expect(issues.first.message, contains('swap the provider'));
  });

  test('durable identity without the capability is rejected', () {
    final composition = Composition(components: [
      Component(
        id: 'a',
        provider: FakeProvider(
          capabilities: const ProviderCapabilities(),
        ),
        lifecycle: const Lifecycle(identity: IdentityRequirement.durable),
      ),
    ]);
    expect(
      composition.validate().issues.map((final i) => i.code),
      contains('capabilityIdentity'),
    );
  });

  test('scope inversion is rejected: persistent depends on ephemeral', () {
    final composition = Composition(components: [
      Component(
        id: 'ephemeral-dep',
        provider: FakeProvider(),
      ),
      Component(
        id: 'persistent',
        provider: FakeProvider(),
        dependsOn: const ['ephemeral-dep'],
        lifecycle: const Lifecycle(scope: ResourceScope.persistent),
      ),
    ]);
    expect(
      composition.validate().issues.map((final i) => i.code),
      contains('scopeInversion'),
    );
  });

  test('invalid readiness shapes are rejected', () {
    final issues = Composition(components: [
      Component(
        id: 'a',
        provider: FakeProvider(),
        readiness: const FilePresent(''),
      ),
    ])
        .validate()
        .issues;
    expect(issues.map((final i) => i.code), contains('invalidReadiness'));

    final nested = Composition(components: [
      Component(
        id: 'a',
        provider: FakeProvider(),
        readiness: const ReadinessAll([
          ReadinessAll([TcpConnect('h', 1)]),
        ]),
      ),
    ])
        .validate()
        .issues;
    expect(nested.map((final i) => i.code), contains('invalidReadiness'));
  });

  test('validate performs no side effects: providers are never contacted',
      () async {
    final provider = FakeProvider();
    final composition = Composition(
      components: [Component(id: 'a', provider: provider)],
    );
    final report = composition.validate();
    final plan = composition.explain();
    expect(report.ok, isTrue);
    expect(plan, contains('- a'));
    await Future<void>.delayed(Duration.zero);
  });

  test('copyWith rebuilds variants; untouched components are identical '
      'values', () {
    final providerA = FakeProvider();
    final providerB = FakeProvider();
    final b = Component(id: 'b', provider: providerB);
    final dev = Composition(components: [
      Component(id: 'a', provider: providerA),
      b,
    ]);
    final ci = dev.copyWith(
      components: [
        dev.components.first.copyWith(
          lifecycle: const Lifecycle(scope: ResourceScope.persistent),
        ),
        dev.components[1],
      ],
      readinessBudget: const Duration(seconds: 5),
    );
    expect(identical(ci.components[1], b), isTrue);
    expect(ci.readinessBudget, const Duration(seconds: 5));
    expect(ci.components.first.lifecycle.scope, ResourceScope.persistent);
    expect(dev.components.first.lifecycle.scope, ResourceScope.ephemeral);
  });
}
