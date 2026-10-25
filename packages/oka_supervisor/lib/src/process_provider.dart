import 'dart:convert';

import 'package:oka_core/oka_core.dart';
import 'package:resource_composition/resource_composition.dart';

import 'spec.dart';

/// Routes the substrate's provider seam to one [LeasedProcessProvider]
/// per declared component: a [ProviderFactory] sees only the provider
/// name, while start/stop/inspect calls always carry the component
/// identity, so per-component commands stay constructor-injected.
final class SupervisorProcessProvider implements ResourceProvider {
  SupervisorProcessProvider({
    required DesiredState desired,
    required String projectRoot,
  }) : _providers = {
         for (final spec in desired.specs)
           spec.id: LeasedProcessProvider(
             leaseId: spec.id,
             runToExit: spec.policy.shape == SupervisionShape.job,
             workingDirectory: spec.env['cwd'] ?? projectRoot,
             command: ProcessCommand(
               _command(spec),
               commandArguments(spec.env),
             ),
             registry: ProcessLeaseRegistry.forProject(projectRoot),
           ),
       };

  static String _command(ComponentSpec spec) {
    final command = spec.env[_commandEnvKey];
    if (command == null || command.trim().isEmpty) {
      throw ArgumentError('spec "${spec.id}" needs env["command"]');
    }
    return command;
  }

  static List<String> commandArguments(Map<String, String> env) {
    final encoded = env['args-json'];
    if (encoded == null) return _splitArgs(env[_argsEnvKey]);
    if (env.containsKey(_argsEnvKey)) {
      throw const FormatException('use args-json or args, not both');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      throw const FormatException('args-json must be a JSON array of strings');
    }
    if (decoded is! List || decoded.any((value) => value is! String)) {
      throw const FormatException('args-json must be a JSON array of strings');
    }
    return decoded.cast<String>();
  }

  static const _commandEnvKey = 'command';
  static const _argsEnvKey = 'args';

  final Map<String, LeasedProcessProvider> _providers;

  /// The factory the supervisor composes with: only `process` resolves;
  /// anything else is a declaration bug, never a crash path.
  ResourceProvider factory(String name) {
    if (name != 'process') {
      throw StateError(
        'unknown provider "$name"; this composition provides: process',
      );
    }
    return this;
  }

  LeasedProcessProvider _for(String componentId) {
    final provider = _providers[componentId];
    if (provider == null) {
      throw StateError(
        'no process provider composed for component "$componentId"',
      );
    }
    return provider;
  }

  static List<String> _splitArgs(String? line) =>
      (line ?? '').split(' ').where((part) => part.isNotEmpty).toList();

  @override
  ProviderCapabilities get capabilities =>
      const ProviderCapabilities(readinessProbe: true, durableIdentity: true);

  @override
  Future<StartReport> start(StartRequest request) =>
      _for(request.component.id).start(request);

  @override
  Future<Observation> inspect(ResourceRef ref) =>
      _for(ref.componentId).inspect(ref);

  @override
  Future<StopReport> stop(ResourceRef ref, {required Duration grace}) =>
      _for(ref.componentId).stop(ref, grace: grace);

  @override
  Future<Observation> reconcile(ResourceRef ref) =>
      _for(ref.componentId).reconcile(ref);
}
