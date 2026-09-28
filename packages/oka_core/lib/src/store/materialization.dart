/// Link-based file materialization (ADR-0028).
///
/// Copies a file into place while sharing its disk blocks with the source
/// whenever the platform supports it: APFS `clonefile` (macOS, copy-on-write)
/// → `FICLONE` reflink (Linux) → hardlink → byte copy. Materialization is an
/// optimization, never a correctness dependency: every failure degrades to
/// the next strategy, ending in a plain copy.
///
/// Law: a materialized file is **never mutated in place**. A hardlink shares
/// its inode with the source, so writers replace via [materializeFile] again
/// (it unlinks the destination first), never by writing through the
/// destination.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

/// How a file was materialized — surfaced for verbose logs and tests.
enum MaterializationStrategy { clonefile, reflink, hardlink, copy }

/// Result of a [materializeFile] call.
final class FileMaterialization {
  const FileMaterialization({
    required this.strategy,
    required this.destination,
    required this.sizeBytes,
  });

  /// Strategy that won the fallback chain.
  final MaterializationStrategy strategy;

  /// Absolute path of the materialized file.
  final String destination;

  /// Logical size of the file in bytes.
  final int sizeBytes;
}

/// One link attempt. Returns the strategy on success, null to fall through
/// to the next attempt. Must never throw.
typedef _LinkAttempt =
    MaterializationStrategy? Function(String source, String destination);

/// Default chain: clonefile (macOS) → reflink (Linux) → hardlink (POSIX).
/// Platform-guarded; unsupported strategies report null immediately.
List<_LinkAttempt> defaultLinkAttempts() => [
  _clonefileAttempt,
  _reflinkAttempt,
  _hardlinkAttempt,
];

/// Materializes [source] at [destination], replacing any existing file.
///
/// [keepSourcePermissions] keeps the source's mode on the materialized copy
/// (clonefile does this inherently); the default sets `0644` — skipped for
/// hardlinks, whose mode is shared with the source inode.
Future<FileMaterialization> materializeFile({
  required final String source,
  required final String destination,
  final bool keepSourcePermissions = false,
  final List<_LinkAttempt>? linkAttempts,
}) async {
  final src = File(source);
  final size = await src.length();
  final destFile = File(destination);
  // Replace semantics: a stale destination (hardlinked to a previous blob,
  // read-only, whatever) must never make the new materialization fail.
  if (await destFile.exists()) {
    try {
      await destFile.delete();
    } on FileSystemException {
      // Fall through — strategies below recreate the path their own way.
    }
  }
  await destFile.parent.create(recursive: true);

  final attempts = linkAttempts ?? defaultLinkAttempts();
  for (final attempt in attempts) {
    final strategy = attempt(source, destination);
    if (strategy != null && await destFile.exists()) {
      if (!keepSourcePermissions && strategy != MaterializationStrategy.hardlink) {
        _chmod(destination, 420);
      }
      return FileMaterialization(
        strategy: strategy,
        destination: destination,
        sizeBytes: size,
      );
    }
  }

  await File(destination).parent.create(recursive: true);
  await src.copy(destination);
  if (!keepSourcePermissions) _chmod(destination, 420);
  return FileMaterialization(
    strategy: MaterializationStrategy.copy,
    destination: destination,
    sizeBytes: size,
  );
}

// --- POSIX chmod (dart:io has no chmod; best-effort, never fatal). -------

void _chmod(final String path, final int mode) {
  if (!Platform.isWindows) {
    try {
      _libcChmod(path, mode);
    } on Object {
      // Permissions are an optimization nicety, not a contract.
    }
  }
}

void _libcChmod(final String path, final int mode) {
  final libc = ffi.DynamicLibrary.process();
  final chmod = libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32),
        int Function(ffi.Pointer<ffi.Char>, int)
      >('chmod');
  final pathPtr = _CString.allocate(path);
  try {
    chmod(pathPtr.pointer, mode);
  } finally {
    pathPtr.free();
  }
}

/// dart:ffi exposes no allocator; libc's malloc/free do the job on every
/// platform the FFI strategies run on (macOS, Linux).
final class _CString {
  factory _CString.allocate(final String value) {
    final libc = ffi.DynamicLibrary.process();
    final mallocFn = libc
        .lookupFunction<
          ffi.Pointer<ffi.Char> Function(ffi.IntPtr),
          ffi.Pointer<ffi.Char> Function(int)
        >('malloc');
    final units = utf8.encode(value);
    final ptr = mallocFn(units.length + 1);
    final bytes = ptr.cast<ffi.Uint8>().asTypedList(units.length + 1);
    bytes.setRange(0, units.length, units);
    bytes[units.length] = 0;
    return _CString._(ptr);
  }

  _CString._(this._pointer);

  final ffi.Pointer<ffi.Char> _pointer;

  ffi.Pointer<ffi.Char> get pointer => _pointer;

  void free() {
    final libc = ffi.DynamicLibrary.process();
    final freeFn = libc
        .lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Char>),
          void Function(ffi.Pointer<ffi.Char>)
        >('free');
    freeFn(_pointer);
  }
}

// --- Strategy 1: APFS clonefile (macOS). ----------------------------------

MaterializationStrategy? _clonefileAttempt(
  final String source,
  final String destination,
) {
  if (!Platform.isMacOS) return null;
  try {
    final libc = ffi.DynamicLibrary.process();
    final clonefile = libc
        .lookupFunction<
          ffi.Int32 Function(
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Char>,
            ffi.Int32,
          ),
          int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, int)
        >('clonefile');
    final srcPtr = _CString.allocate(source);
    final dstPtr = _CString.allocate(destination);
    try {
      // flags = 0: follow symlinks, copy ownership (CoW — safe to chmod).
      return clonefile(srcPtr.pointer, dstPtr.pointer, 0) == 0
          ? MaterializationStrategy.clonefile
          : null;
    } finally {
      srcPtr.free();
      dstPtr.free();
    }
  } on Object {
    return null;
  }
}

// --- Strategy 2: FICLONE reflink (Linux). ---------------------------------

/// FICLONE ioctl request number from `<linux/fs.h>`.
const _kFiclone = 0x40049409;

MaterializationStrategy? _reflinkAttempt(
  final String source,
  final String destination,
) {
  if (!Platform.isLinux) return null;
  var srcFd = -1;
  var dstFd = -1;
  try {
    final libc = ffi.DynamicLibrary.process();
    final open = libc
        .lookupFunction<
          ffi.Int32 Function(
            ffi.Pointer<ffi.Char>,
            ffi.Int32,
            ffi.Int32,
          ),
          int Function(ffi.Pointer<ffi.Char>, int, int)
        >('open');
    final ioctl = libc
        .lookupFunction<
          ffi.IntPtr Function(ffi.Int32, ffi.UintPtr, ffi.IntPtr),
          int Function(int, int, int)
        >('ioctl');
    final close = libc
        .lookupFunction<ffi.Int32 Function(ffi.Int32), int Function(int)>(
          'close',
        );
    const oRdonly = 0;
    // O_WRONLY | O_CREAT | O_TRUNC, mode 0644.
    const oWronlyCreatTrunc = 0x241;
    final srcPtr = _CString.allocate(source);
    final dstPtr = _CString.allocate(destination);
    try {
      srcFd = open(srcPtr.pointer, oRdonly, 0);
      if (srcFd < 0) return null;
      dstFd = open(dstPtr.pointer, oWronlyCreatTrunc, 420);
      if (dstFd < 0) return null;
      return ioctl(dstFd, _kFiclone, srcFd) == 0
          ? MaterializationStrategy.reflink
          : null;
    } finally {
      if (srcFd >= 0) close(srcFd);
      if (dstFd >= 0) close(dstFd);
    }
  } on Object {
    return null;
  }
}

// --- Strategy 3: hardlink (POSIX). -----------------------------------------

MaterializationStrategy? _hardlinkAttempt(
  final String source,
  final String destination,
) {
  if (Platform.isWindows) return null;
  try {
    final libc = ffi.DynamicLibrary.process();
    final link = libc
        .lookupFunction<
          ffi.Int32 Function(
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Char>,
          ),
          int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>)
        >('link');
    final srcPtr = _CString.allocate(source);
    final dstPtr = _CString.allocate(destination);
    try {
      return link(srcPtr.pointer, dstPtr.pointer) == 0
          ? MaterializationStrategy.hardlink
          : null;
    } finally {
      srcPtr.free();
      dstPtr.free();
    }
  } on Object {
    return null;
  }
}
