import 'dart:ffi';
import 'dart:io';

const _prSetChildSubreaper = 36;

bool activateChildSubreaper() {
  if (!Platform.isLinux) return false;
  final libc = DynamicLibrary.open('libc.so.6');
  final prctl = libc.lookupFunction<
      Int32 Function(Uint32, Uint64, Uint64, Uint64, Uint64),
      int Function(int, int, int, int, int)>('prctl');
  return prctl(_prSetChildSubreaper, 1, 0, 0, 0) == 0;
}

int readCurrentProcessId() {
  if (!Platform.isLinux) return -1;
  final libc = DynamicLibrary.open('libc.so.6');
  final getpid = libc.lookupFunction<Int32 Function(), int Function()>('getpid');
  return getpid();
}
