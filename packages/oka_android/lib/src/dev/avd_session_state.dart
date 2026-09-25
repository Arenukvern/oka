/// Inventory-only managed session-state workflow for Android AVDs.
///
/// Android's available AVD and adb inventory commands do not prove host-wide
/// inactivity: an emulator may be running outside the visible adb server.
/// This workflow therefore records AVDs as persistent, caller-owned opaque
/// resources and never provisions, resets, or deletes them. Inspection can
/// positively report a visible matching emulator as busy; all other outcomes
/// remain unknown.
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'adb_tool.dart';

/// Result of resolving the directory Android uses to inventory AVDs.
@immutable
final class AndroidAvdHomeResolution {
  const AndroidAvdHomeResolution._({this.path, this.limitation});

  factory AndroidAvdHomeResolution.resolved(final String path) =>
      AndroidAvdHomeResolution._(path: path);

  factory AndroidAvdHomeResolution.unavailable(final String reason) =>
      AndroidAvdHomeResolution._(limitation: reason);

  final String? path;
  final String? limitation;

  bool get isResolved => path != null;
}

/// Resolves the AVD inventory directory using Android's documented search
/// locations. An explicit path is authoritative; it is never replaced by a
/// guessed fallback. A directory is accepted only when it contains the
/// selected AVD's `.ini` inventory entry.
Future<AndroidAvdHomeResolution> resolveAndroidAvdHome({
  required final String avdName,
  final String? explicit,
  final Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final List<String> candidates;
  if (explicit != null) {
    candidates = [explicit];
  } else {
    candidates = [
      if (env['ANDROID_AVD_HOME']?.trim().isNotEmpty ?? false)
        env['ANDROID_AVD_HOME']!.trim(),
      if (env['ANDROID_USER_HOME']?.trim().isNotEmpty ?? false)
        p.join(env['ANDROID_USER_HOME']!.trim(), 'avd'),
      if (env['ANDROID_SDK_HOME']?.trim().isNotEmpty ?? false)
        p.join(env['ANDROID_SDK_HOME']!.trim(), '.android', 'avd'),
      if ((env['HOME'] ?? env['USERPROFILE'])?.trim().isNotEmpty ?? false)
        p.join((env['HOME'] ?? env['USERPROFILE'])!.trim(), '.android', 'avd'),
    ];
  }

  if (candidates.isEmpty) {
    return AndroidAvdHomeResolution.unavailable(
      'Android AVD home could not be resolved: set ANDROID_AVD_HOME or '
      'ANDROID_USER_HOME, or provide an explicit avdHome path.',
    );
  }
  for (final candidate in candidates) {
    if (!p.isAbsolute(candidate)) continue;
    final directory = Directory(p.normalize(candidate));
    try {
      if (!await directory.exists() ||
          !await File(p.join(directory.path, '$avdName.ini')).exists()) {
        continue;
      }
      return AndroidAvdHomeResolution.resolved(
        p.normalize(await directory.resolveSymbolicLinks()),
      );
    } on Object {
      // An inaccessible or disappearing directory is an observation
      // limitation, not a reason to block an otherwise successful target.
    }
  }
  return AndroidAvdHomeResolution.unavailable(
    'Android AVD home could not be resolved for "$avdName": no absolute '
    'candidate directory contains "$avdName.ini". The emulator target '
    'completed, but no inventory lease was recorded.',
  );
}

/// An Android Virtual Device identity restored from a durable state lease.
@immutable
final class AndroidAvdHandle {
  const AndroidAvdHandle({required this.name, required this.avdHome});

  final String name;

  /// Inventory location supplied by the caller. It is not a
  /// filesystem-management authority and is never used for deletion.
  final String avdHome;
}

/// Pure planner for persistent, host-scoped AVD inventory records.
///
/// Supply the actual `avd_home` and `avd_name` in
/// [SessionStateRequest.metadata]. `avd_home` is required because a fabricated
/// inventory path would misrepresent where the opaque resource lives.
final class AndroidAvdPlanner implements SessionStatePlanner<AndroidAvdHandle> {
  const AndroidAvdPlanner();

  @override
  String get id => 'android-avd-plan';

  @override
  SessionStatePlan<AndroidAvdHandle> plan(final SessionStateRequest request) {
    final nameValue = request.metadata['avd_name'];
    if (nameValue is! String || nameValue.trim().isEmpty) {
      throw ArgumentError('Android AVD request needs a non-empty avd_name.');
    }
    final homeValue = request.metadata['avd_home'];
    if (homeValue is! String ||
        homeValue.trim().isEmpty ||
        !p.isAbsolute(homeValue)) {
      throw ArgumentError(
        'Android AVD request needs an absolute avd_home inventory path.',
      );
    }
    final name = nameValue.trim();
    final avdHome = p.normalize(homeValue);
    return SessionStatePlan(
      logicalResourceKey: 'android-avd:$avdHome:$name',
      namespace: SessionStateNamespace.host,
      retention: SessionStateRetention.persistent,
      processScope: LeaseScope.persistent,
      ownership: SessionStateOwnership.caller,
      acquisitionMode: SessionStateAcquisitionMode.borrowed,
      resourceKind: SessionStateResourceKind.opaque,
      rootPath: avdHome,
      relativePath: name,
      handle: AndroidAvdHandle(name: name, avdHome: avdHome),
      metadata: {
        'provider': 'android-avd',
        'avd_name': name,
        'avd_home': avdHome,
      },
    );
  }
}

/// Restores an AVD identity from the durable inventory lease.
final class AndroidAvdSource implements SessionStateSource<AndroidAvdHandle> {
  const AndroidAvdSource();

  @override
  String get id => 'android-avd-source';

  @override
  Future<AndroidAvdHandle> restore(final SessionStateLease lease) async {
    final name = lease.metadata['avd_name'];
    if (name is! String || name.isEmpty) {
      throw FormatException(
        'Android AVD lease "${lease.id}" has no valid avd_name metadata.',
      );
    }
    final home = lease.metadata['avd_home'];
    if (home is! String || home.isEmpty || !p.isAbsolute(home)) {
      throw FormatException(
        'Android AVD lease "${lease.id}" has no valid absolute avd_home.',
      );
    }
    return AndroidAvdHandle(name: name, avdHome: home);
  }
}

typedef AndroidAvdDeviceLister = Future<List<AdbDevice>> Function();
typedef AndroidAvdNameReader = Future<String?> Function(String serial);

/// Reports positive observations of an AVD currently visible through adb.
///
/// The adb server is not a host-global process inventory. In particular, an
/// empty device list is never treated as proof of inactivity.
final class AndroidAvdUseInspector
    implements SessionStateInspector<AndroidAvdHandle> {
  const AndroidAvdUseInspector({
    this.adbPath,
    this.timeout = const Duration(seconds: 5),
    this.listDevices,
    this.readAvdName,
  });

  final String? adbPath;
  final Duration timeout;
  final AndroidAvdDeviceLister? listDevices;
  final AndroidAvdNameReader? readAvdName;

  @override
  String get id => 'android-avd-adb-observation';

  Future<List<AdbDevice>> _listDevices() async {
    final result = await Process.run(
      adbPath ?? 'adb',
      adbDevicesArgs(),
    ).timeout(timeout);
    if (result.exitCode != 0) {
      throw StateError('adb devices exited with ${result.exitCode}.');
    }
    return parseAdbDevices(result.stdout.toString());
  }

  Future<String?> _readAvdName(final String serial) async {
    final result = await Process.run(adbPath ?? 'adb', [
      '-s',
      serial,
      'emu',
      'avd',
      'name',
    ]).timeout(timeout);
    if (result.exitCode != 0) {
      throw StateError('adb emu avd name for $serial failed.');
    }
    return parseEmuAvdName(result.stdout.toString());
  }

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<AndroidAvdHandle> context,
  ) async {
    final devices = <AdbDevice>[];
    try {
      devices.addAll(await (listDevices ?? _listDevices)());
      for (final device in devices.where(
        (final item) => item.id.startsWith('emulator-'),
      )) {
        final name = await (readAvdName ?? _readAvdName)(device.id);
        if (name == context.handle.name) {
          return SessionStateFinding(
            inspectorId: id,
            use: SessionStateUse.busy,
            reason: 'A matching emulator is visible through the adb server.',
            details: {'avd_name': name, 'serial': device.id},
          );
        }
        if (!device.ready || name == null) {
          return SessionStateFinding(
            inspectorId: id,
            use: SessionStateUse.unknown,
            reason: 'A visible emulator could not be fully identified.',
            details: {'serial': device.id, 'state': device.state},
          );
        }
      }
    } on Object catch (error) {
      return SessionStateFinding(
        inspectorId: id,
        use: SessionStateUse.unknown,
        reason: 'Could not inspect adb emulator inventory: $error',
        details: {'avd_name': context.handle.name},
      );
    }
    return SessionStateFinding(
      inspectorId: id,
      use: SessionStateUse.unknown,
      reason: 'adb inventory cannot prove host-global AVD inactivity.',
      details: {
        'avd_name': context.handle.name,
        'visible_emulator_count': devices
            .where((final device) => device.id.startsWith('emulator-'))
            .length,
      },
    );
  }
}

/// Default Android AVD workflow: durable inventory only, with no state
/// creation, userdata reset, automatic cleanup, or inactive-state assertion.
const androidAvdStateWorkflow = SessionStateWorkflow<AndroidAvdHandle>(
  id: 'oka.android-avd',
  version: 1,
  plan: AndroidAvdPlanner(),
  source: AndroidAvdSource(),
  inspectors: [AndroidAvdUseInspector()],
);

/// Records the selected AVD after the emulator target has booted successfully.
///
/// Failure to resolve or record inventory is deliberately non-fatal: this
/// workflow adds visibility only and does not own or manage AVD data.
const _emulatorSerialArtifact = Artifact<String>('emulator-serial');

class RecordAndroidAvdInventoryStep extends BuildStep {
  RecordAndroidAvdInventoryStep({
    required this.avdName,
    this.avdHome,
    this.registry,
    this.liveness,
  });

  final String avdName;
  final String? avdHome;
  final SessionStateRegistry? registry;
  final ProcessLiveness? liveness;

  @override
  String get name => 'record-android-avd-inventory';

  @override
  Set<Artifact<Object>> get requires => {_emulatorSerialArtifact};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final AndroidAvdHomeResolution resolution;
    try {
      resolution = await resolveAndroidAvdHome(
        avdName: avdName,
        explicit: avdHome,
      );
    } on Object catch (error) {
      final limitation =
          'Android emulator target completed, but its AVD home could not be '
          'observed: $error';
      print('⚠️ $limitation');
      return StepResult.success({
        'avd_inventory': 'unavailable',
        'limitation': limitation,
      });
    }
    if (!resolution.isResolved) {
      print('⚠️ ${resolution.limitation}');
      return StepResult.success({
        'avd_inventory': 'unavailable',
        'limitation': resolution.limitation,
      });
    }
    final resolvedHome = resolution.path;

    try {
      final lease =
          await SessionStateManager(
            registry: registry ?? SessionStateRegistry.forCurrentUser(),
            liveness: liveness ?? const HostProcessLiveness(),
          ).acquire(
            androidAvdStateWorkflow,
            SessionStateRequest(
              projectPath: ctx.projectPath,
              sessionName: avdName,
              metadata: {'avd_name': avdName, 'avd_home': resolvedHome},
            ),
          );
      return StepResult.success({
        'avd_inventory': lease.id,
        'avd_name': avdName,
        'avd_home': resolvedHome,
      });
    } on Object catch (error) {
      final limitation =
          'Android emulator target completed, but its AVD inventory lease '
          'could not be recorded: $error';
      print('⚠️ $limitation');
      return StepResult.success({
        'avd_inventory': 'unavailable',
        'limitation': limitation,
      });
    }
  }
}
