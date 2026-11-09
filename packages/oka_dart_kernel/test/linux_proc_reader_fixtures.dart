import 'package:oka_dart_kernel/src/gate/linux_proc_process_tree_probe.dart';

final class DenyLinuxProcStatReader implements LinuxProcStatReader {
  DenyLinuxProcStatReader({required this.denyPid, this.inner = const HostLinuxProcStatReader()});

  final int denyPid;
  final HostLinuxProcStatReader inner;

  @override
  Future<List<int>> listProcPids() => inner.listProcPids();

  @override
  Future<LinuxProcStatRead> readStat(int pid) async {
    if (pid == denyPid) {
      return const LinuxProcStatRead.error('EACCES injected');
    }
    return inner.readStat(pid);
  }
}

final class HidePidListLinuxProcStatReader implements LinuxProcStatReader {
  HidePidListLinuxProcStatReader({
    required this.hidePid,
    this.hideThroughListCall = 3,
    this.inner = const HostLinuxProcStatReader(),
  });

  final int hidePid;
  final int hideThroughListCall;
  final HostLinuxProcStatReader inner;
  var _listCalls = 0;

  @override
  Future<List<int>> listProcPids() async {
    _listCalls++;
    final all = await inner.listProcPids();
    if (_listCalls <= hideThroughListCall) {
      return all.where((p) => p != hidePid).toList();
    }
    return all;
  }

  @override
  Future<LinuxProcStatRead> readStat(int pid) => inner.readStat(pid);
}

final class SlowLinuxProcStatReader implements LinuxProcStatReader {
  SlowLinuxProcStatReader({
    required this.perStatDelay,
    this.inner = const HostLinuxProcStatReader(),
  });

  final Duration perStatDelay;
  final HostLinuxProcStatReader inner;

  @override
  Future<List<int>> listProcPids() => inner.listProcPids();

  @override
  Future<LinuxProcStatRead> readStat(int pid) async {
    await Future<void>.delayed(perStatDelay);
    return inner.readStat(pid);
  }
}
