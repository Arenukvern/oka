import 'package:oka_dart_kernel/src/unit_graph.dart';
import 'package:test/test.dart';

Uri _u(String s) => Uri.parse(s);

/// Graph: entry -> barrel, shared; barrel -> src1; src1 -> src2;
/// src2 -> shared (shared is reachable from root too -> stays in root).
UnitGraph _sharedLibGraph() => UnitGraph(
      entry: _u('file:///app/main.dart'),
      imports: {
        _u('file:///app/main.dart'): [
          _u('package:ua/barrel.dart'),
          _u('package:shared/shared.dart'),
        ],
        _u('package:ua/barrel.dart'): [_u('package:ua/src/a1.dart')],
        _u('package:ua/src/a1.dart'): [_u('package:ua/src/a2.dart')],
        _u('package:ua/src/a2.dart'): [_u('package:shared/shared.dart')],
        _u('package:shared/shared.dart'): [],
      },
    );

void main() {
  test('single unit: closure absorbed, shared library stays in root', () {
    final plan = _sharedLibGraph().partition(['package:ua/']);

    expect(plan.units, hasLength(1));
    final unit = plan.units.single;
    expect(unit.pattern, 'package:ua/');
    expect(
      unit.members,
      [
        _u('package:ua/barrel.dart'),
        _u('package:ua/src/a1.dart'),
        _u('package:ua/src/a2.dart'),
      ],
    );
    expect(unit.guardSeed, _u('package:ua/barrel.dart'));

    expect(
      plan.deferredEdges,
      [UriEdge(_u('file:///app/main.dart'), _u('package:ua/barrel.dart'))],
    );
    expect(plan.sharedLibraries, [_u('package:shared/shared.dart')]);
  });

  test('inter-unit dependency orders the DAG (dependency loads first)', () {
    final graph = UnitGraph(
      entry: _u('file:///app/main.dart'),
      imports: {
        _u('file:///app/main.dart'): [
          _u('package:ub/b.dart'),
          _u('package:ua/a.dart'),
        ],
        _u('package:ub/b.dart'): [_u('package:ua/a.dart')],
        _u('package:ua/a.dart'): [],
      },
    );

    final plan = graph.partition(['package:ub/', 'package:ua/']);

    expect(plan.units.map((u) => u.pattern).toList(), ['package:ua/', 'package:ub/']);
    expect(plan.deferredEdges, containsAll([
      UriEdge(_u('file:///app/main.dart'), _u('package:ua/a.dart')),
      UriEdge(_u('file:///app/main.dart'), _u('package:ub/b.dart')),
      UriEdge(_u('package:ub/b.dart'), _u('package:ua/a.dart')),
    ]));
  });

  test('cycle between units is refused', () {
    final graph = UnitGraph(
      entry: _u('file:///app/main.dart'),
      imports: {
        _u('file:///app/main.dart'): [
          _u('package:ua/a.dart'),
          _u('package:ub/b.dart'),
        ],
        _u('package:ua/a.dart'): [_u('package:ub/b.dart')],
        _u('package:ub/b.dart'): [_u('package:ua/a.dart')],
      },
    );

    expect(
      () => graph.partition(['package:ua/', 'package:ub/']),
      throwsA(
        isA<UnitPartitionException>().having(
          (e) => e.message,
          'message',
          contains('cycle'),
        ),
      ),
    );
  });

  test('unknown pattern is refused', () {
    expect(
      () => _sharedLibGraph().partition(['package:missing/']),
      throwsA(isA<UnitPartitionException>()),
    );
  });

  test('pattern suffix form matches file-style units', () {
    final graph = UnitGraph(
      entry: _u('file:///app/main.dart'),
      imports: {
        _u('file:///app/main.dart'): [_u('file:///app/units/tiny.dart')],
        _u('file:///app/units/tiny.dart'): [],
      },
    );

    final plan = graph.partition(['units/tiny.dart']);
    expect(plan.units.single.members, [_u('file:///app/units/tiny.dart')]);
  });

  test('unit-internal import is not deferred', () {
    final plan = _sharedLibGraph().partition(['package:ua/']);
    final internal = UriEdge(
      _u('package:ua/src/a1.dart'),
      _u('package:ua/src/a2.dart'),
    );
    expect(plan.deferredEdges, isNot(contains(internal)));
  });
}
