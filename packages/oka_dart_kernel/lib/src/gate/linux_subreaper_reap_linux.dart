import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _wnohang = 1;

/// Reaps one or more zombie children of this process via waitpid(WNOHANG).
int reapAvailableChildZombiesImpl() {
  if (!Platform.isLinux) return 0;
  final libc = DynamicLibrary.open('libc.so.6');
  final waitpid = libc.lookupFunction<
      Int32 Function(Int32, Pointer<Int32>, Int32),
      int Function(int, Pointer<Int32>, int)>('waitpid');
  var reaped = 0;
  while (true) {
    final status = calloc<Int32>();
    try {
      final pid = waitpid(-1, status, _wnohang);
      if (pid <= 0) break;
      reaped++;
    } finally {
      calloc.free(status);
    }
  }
  return reaped;
}

bool tryReapChildZombieImpl(int pid) {
  if (!Platform.isLinux || pid <= 0) return false;
  final libc = DynamicLibrary.open('libc.so.6');
  final waitpid = libc.lookupFunction<
      Int32 Function(Int32, Pointer<Int32>, Int32),
      int Function(int, Pointer<Int32>, int)>('waitpid');
  final status = calloc<Int32>();
  try {
    final result = waitpid(pid, status, _wnohang);
    return result == pid;
  } finally {
    calloc.free(status);
  }
}
