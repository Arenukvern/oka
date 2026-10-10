/// The authored plan format: JSON ⇄ typed desired state (ADR-0041).
///
/// Specs stay Dart values (ADR-0040 decision 8); this codec is the one
/// seam where declarations cross process boundaries — a plan file in git,
/// an app-authored automation on device, a mesh frame. It is an explicit,
/// discriminated schema, not the revision-hash projection
/// ([ComponentSpec.toCanonicalJson] stays hashing-only): decode → encode
/// round-trips to identical [ComponentSpec.revisionHash] values.
///
/// What JSON cannot carry: [HandshakeLine.parse] closures. A decoded
/// handshake matches only; line-to-output parsing stays a Dart-side
/// composition-root concern.
library;

import 'dart:convert';

import 'package:resource_composition/resource_composition.dart';

import 'spec.dart';

/// A structurally invalid plan document. Never a provider fault: nothing
/// was contacted, nothing was started.
final class SpecFormatException implements Exception {
  const SpecFormatException(this.message);

  final String message;

  @override
  String toString() => 'invalid supervisor plan: $message';
}

/// Decodes and encodes plan documents.
///
/// ```json
/// {
///   "version": 1,
///   "readinessBudgetMs": 30000,
///   "specs": [
///     {
///       "id": "api", "provider": "process", "shape": "service",
///       "dependsOn": [], "requires": [], "provides": [],
///       "readiness": {
///         "kind": "tcpConnect", "host": "127.0.0.1", "port": 8080},
///       "policy": {"maxRestarts": 3, "restartWindowS": 120, "revision": 1},
///       "trigger": {"kind": "none"},
///       "env": {}
///     }
///   ]
/// }
/// ```
final class SpecCodec {
  const SpecCodec();

  /// The current plan-schema version this codec reads and writes.
  static const int version = 1;

  /// Parses a plan document into typed desired state.
  ///
  /// Throws [SpecFormatException] on any structural problem (bad JSON,
  /// wrong types, unknown kinds, duplicate ids, empty id/provider).
  /// Validation that needs a provider factory stays with
  /// [DesiredState.validate].
  DesiredState decode(final String json) {
    final Object? document;
    try {
      document = jsonDecode(json);
    } on FormatException catch (error) {
      throw SpecFormatException('not valid JSON: ${error.message}');
    }
    if (document is! Map<String, Object?>) {
      throw const SpecFormatException('top level must be a JSON object');
    }
    return _decodeDocument(document);
  }

  /// Renders desired state as the authored plan format (indented JSON).
  ///
  /// Round-trip law: `decode(encode(d))` yields the same
  /// [ComponentSpec.revisionHash] per spec and the same readiness budget.
  String encode(final DesiredState desired) =>
      const JsonEncoder.withIndent('  ').convert(_encodeDocument(desired));

  DesiredState _decodeDocument(final Map<String, Object?> document) {
    final versionValue = document['version'];
    if (versionValue is! int || versionValue != version) {
      throw SpecFormatException(
        'unsupported plan version $versionValue (expected $version)',
      );
    }
    final specsValue = document['specs'];
    if (specsValue is! List<Object?>) {
      throw const SpecFormatException('"specs" must be an array');
    }
    final specs = <ComponentSpec>[];
    final seen = <String>{};
    for (final specValue in specsValue) {
      if (specValue is! Map<String, Object?>) {
        throw const SpecFormatException('every spec must be an object');
      }
      final spec = _decodeSpec(specValue);
      if (!seen.add(spec.id)) {
        throw SpecFormatException('duplicate spec id "${spec.id}"');
      }
      specs.add(spec);
    }
    final budgetValue = document['readinessBudgetMs'];
    final budget = switch (budgetValue) {
      null => const Duration(seconds: 30),
      final int ms => Duration(milliseconds: ms),
      _ => throw const SpecFormatException(
        '"readinessBudgetMs" must be an integer',
      ),
    };
    return DesiredState(specs: specs, readinessBudget: budget);
  }

  ComponentSpec _decodeSpec(final Map<String, Object?> value) {
    final id = value['id'];
    final provider = value['provider'] ?? value['providerName'];
    if (id is! String || id.isEmpty) {
      throw const SpecFormatException('spec "id" must be a non-empty string');
    }
    if (provider is! String || provider.isEmpty) {
      throw SpecFormatException(
        'spec "$id": "provider" must be a non-empty string',
      );
    }
    return ComponentSpec(
      id: id,
      providerName: provider,
      dependsOn: _stringList(value, 'dependsOn', id),
      requires: _stringList(value, 'requires', id),
      provides: _stringList(value, 'provides', id),
      readiness: _decodeReadiness(value['readiness'], 'spec "$id"'),
      policy: _decodePolicy(value, id),
      trigger: _decodeTrigger(value['trigger'], id),
      env: _decodeEnv(value['env'], id),
    );
  }

  SupervisionPolicy _decodePolicy(
    final Map<String, Object?> spec,
    final String id,
  ) {
    final shape = _shapeOf(spec, id);
    final value = spec['policy'];
    if (value == null) return SupervisionPolicy(shape: shape);
    if (value is! Map<String, Object?>) {
      throw SpecFormatException('spec "$id": "policy" must be an object');
    }
    return SupervisionPolicy(
      shape: shape,
      maxRestarts: _intOf(value['maxRestarts'], 'maxRestarts', id, fallback: 3),
      restartWindow: Duration(
        seconds: _intOf(
          value['restartWindowS'],
          'restartWindowS',
          id,
          fallback: 120,
        ),
      ),
      revision: _intOf(value['revision'], 'revision', id, fallback: 1),
    );
  }

  /// The spec-level `shape` key — where [SpecCodec.encode] writes
  /// [SupervisionPolicy.shape] (the policy object carries only budgets).
  SupervisionShape _shapeOf(final Map<String, Object?> spec, final String id) {
    final shapeValue = spec['shape'];
    return switch (shapeValue) {
      null => SupervisionShape.service,
      'service' => SupervisionShape.service,
      'job' => SupervisionShape.job,
      _ => throw SpecFormatException(
        'spec "$id": "shape" must be "service" or "job"',
      ),
    };
  }

  Trigger _decodeTrigger(final Object? value, final String id) {
    if (value == null) return const NoTrigger();
    if (value is! Map<String, Object?>) {
      throw SpecFormatException('spec "$id": "trigger" must be an object');
    }
    switch (value['kind']) {
      case 'none':
        return const NoTrigger();
      case 'watch':
        final roots = value['roots'];
        if (roots is! List<Object?> || roots.isEmpty) {
          throw SpecFormatException(
            'spec "$id": watch trigger needs a non-empty "roots" array',
          );
        }
        return WatchTrigger(
          roots: roots.cast<String>(),
          extensions: _optionalStringList(value['extensions']),
          debounce: Duration(
            milliseconds: _intOf(
              value['debounceMs'],
              'debounceMs',
              id,
              fallback: 500,
            ),
          ),
        );
      case 'interval':
        final periodValue = value['periodS'];
        if (periodValue is! int || periodValue <= 0) {
          throw SpecFormatException(
            'spec "$id": interval trigger needs a positive "periodS"',
          );
        }
        return IntervalTrigger(period: Duration(seconds: periodValue));
      case final Object? unknown:
        throw SpecFormatException(
          'spec "$id": unknown trigger kind "$unknown"',
        );
    }
  }

  Readiness? _decodeReadiness(final Object? value, final String at) {
    if (value == null) return null;
    if (value is! Map<String, Object?>) {
      throw SpecFormatException('$at: "readiness" must be an object or null');
    }
    final budget = switch (value['budgetMs']) {
      null => null,
      final int ms => Duration(milliseconds: ms),
      _ => throw SpecFormatException(
        '$at: readiness "budgetMs" must be an integer',
      ),
    };
    switch (value['kind']) {
      case 'handshakeLine':
        return HandshakeLine(
          pattern: _optionalPattern(value['pattern'], at),
          budget: budget,
        );
      case 'filePresent':
        final path = value['path'];
        if (path is! String || path.isEmpty) {
          throw SpecFormatException('$at: filePresent needs a "path" string');
        }
        final absence = value['absenceIsLiveness'];
        return FilePresent(
          path,
          budget: budget,
          absenceIsLiveness: absence is! bool || absence,
        );
      case 'logPattern':
        return LogPattern(
          _requiredPattern(value['pattern'], at),
          budget: budget,
        );
      case 'tcpConnect':
        final host = value['host'];
        final port = value['port'];
        if (host is! String ||
            host.isEmpty ||
            port is! int ||
            port <= 0 ||
            port > 65535) {
          throw SpecFormatException(
            '$at: tcpConnect needs a "host" string and a "port" in 1..65535',
          );
        }
        return TcpConnect(host, port, budget: budget);
      case 'readinessAll':
        final conditions = value['all'];
        if (conditions is! List<Object?> || conditions.isEmpty) {
          throw SpecFormatException(
            '$at: readinessAll needs a non-empty "all" array',
          );
        }
        return ReadinessAll([
          for (var i = 0; i < conditions.length; i++)
            _decodeReadiness(conditions[i], '$at all[$i]')!,
        ], budget: budget);
      case final Object? unknown:
        throw SpecFormatException('$at: unknown readiness kind "$unknown"');
    }
  }

  Map<String, String> _decodeEnv(final Object? value, final String id) {
    if (value == null) return const <String, String>{};
    if (value is! Map<String, Object?>) {
      throw SpecFormatException('spec "$id": "env" must be an object');
    }
    final env = <String, String>{};
    for (final entry in value.entries) {
      final envValue = entry.value;
      if (envValue is! String) {
        throw SpecFormatException(
          'spec "$id": env["${entry.key}"] must be a string',
        );
      }
      env[entry.key] = envValue;
    }
    return env;
  }

  List<String> _stringList(
    final Map<String, Object?> value,
    final String key,
    final String id,
  ) {
    final list = value[key];
    if (list == null) return const <String>[];
    if (list is! List<Object?>) {
      throw SpecFormatException('spec "$id": "$key" must be an array');
    }
    for (final element in list) {
      if (element is! String) {
        throw SpecFormatException('spec "$id": "$key" entries must be strings');
      }
    }
    return List.of(list.cast<String>());
  }

  List<String> _optionalStringList(final Object? value) {
    if (value == null) return const <String>[];
    if (value is! List<Object?>) {
      throw const SpecFormatException('"extensions" must be an array');
    }
    for (final element in value) {
      if (element is! String) {
        throw const SpecFormatException('"extensions" entries must be strings');
      }
    }
    return List.of(value.cast<String>());
  }

  Pattern? _optionalPattern(final Object? value, final String at) {
    if (value == null) return null;
    return _requiredPattern(value, at);
  }

  Pattern _requiredPattern(final Object? value, final String at) {
    if (value is! String || value.isEmpty) {
      throw SpecFormatException('$at: "pattern" must be a non-empty string');
    }
    return RegExp(value);
  }

  int _intOf(
    final Object? value,
    final String key,
    final String id, {
    required final int fallback,
  }) {
    if (value == null) return fallback;
    if (value is! int || value < 0) {
      throw SpecFormatException(
        'spec "$id": policy "$key" must be a non-negative integer',
      );
    }
    return value;
  }

  Map<String, Object?> _encodeDocument(final DesiredState desired) => {
    'version': version,
    'readinessBudgetMs': desired.readinessBudget.inMilliseconds,
    'specs': [for (final spec in desired.specs) _encodeSpec(spec)],
  };

  Map<String, Object?> _encodeSpec(final ComponentSpec spec) => {
    'id': spec.id,
    'provider': spec.providerName,
    'shape': spec.policy.shape.name,
    'dependsOn': List<String>.of(spec.dependsOn),
    'requires': List<String>.of(spec.requires),
    'provides': List<String>.of(spec.provides),
    'readiness': spec.readiness == null
        ? null
        : _encodeReadiness(spec.readiness!),
    'policy': {
      'maxRestarts': spec.policy.maxRestarts,
      'restartWindowS': spec.policy.restartWindow.inSeconds,
      'revision': spec.policy.revision,
    },
    'trigger': _encodeTrigger(spec.trigger),
    'env': Map<String, String>.of(spec.env),
  };

  Map<String, Object?> _encodeTrigger(final Trigger trigger) =>
      switch (trigger) {
        NoTrigger() => {'kind': 'none'},
        WatchTrigger(:final roots, :final extensions, :final debounce) => {
          'kind': 'watch',
          'roots': List<String>.of(roots),
          'extensions': List<String>.of(extensions),
          'debounceMs': debounce.inMilliseconds,
        },
        IntervalTrigger(:final period) => {
          'kind': 'interval',
          'periodS': period.inSeconds,
        },
      };

  Map<String, Object?> _encodeReadiness(final Readiness readiness) =>
      switch (readiness) {
        HandshakeLine(:final pattern, :final budget) => {
          'kind': 'handshakeLine',
          'pattern': _patternText(pattern, 'handshakeLine'),
          if (budget != null) 'budgetMs': budget.inMilliseconds,
        },
        FilePresent(:final path, :final budget, :final absenceIsLiveness) => {
          'kind': 'filePresent',
          'path': path,
          'absenceIsLiveness': absenceIsLiveness,
          if (budget != null) 'budgetMs': budget.inMilliseconds,
        },
        LogPattern(:final pattern, :final budget) => {
          'kind': 'logPattern',
          'pattern': _patternText(pattern, 'logPattern'),
          if (budget != null) 'budgetMs': budget.inMilliseconds,
        },
        TcpConnect(:final host, :final port, :final budget) => {
          'kind': 'tcpConnect',
          'host': host,
          'port': port,
          if (budget != null) 'budgetMs': budget.inMilliseconds,
        },
        ReadinessAll(:final conditions, :final budget) => {
          'kind': 'readinessAll',
          'all': [
            for (final condition in conditions) _encodeReadiness(condition),
          ],
          if (budget != null) 'budgetMs': budget.inMilliseconds,
        },
      };

  String _patternText(final Pattern? pattern, final String at) {
    if (pattern is RegExp) return pattern.pattern;
    if (pattern is String) return pattern;
    throw SpecFormatException(
      '$at: only RegExp and String patterns are encodable '
      '(got ${pattern?.runtimeType})',
    );
  }
}
