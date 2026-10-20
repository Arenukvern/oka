/// Advisory lock on one persistent inode, kernel-released on process death
/// (ADR-0047).
///
/// The build single-flight dialect of the oka process substrate. Where
/// [DirectoryProcessLock] owns long-lived lanes (mkdir-exclusive + pid
/// file + liveness + stale-steal), [InodeLock] owns short-lived builders:
/// an exclusive lock on a file that is never deleted. A killed compiler
/// cannot leave a stale lock behind — the kernel drops the lock — so
/// there is no liveness judgment to get wrong and no pid-reuse double-run.
///
/// The lock path must stay alive for the lock's lifetime: deleting the
/// inode while a holder keeps it locked would let a second acquirer lock
/// a fresh inode and run concurrently.
library;

import 'dart:io';

/// Single-flight mutex for artifact builds across processes.
final class InodeLock {
  InodeLock._(this._file);

  final RandomAccessFile _file;

  /// Tries to take an exclusive lock on [path], creating it if missing.
  ///
  /// Returns `null` when another process holds the lock. POSIX fcntl
  /// locks are owned per process: contention is only meaningful across
  /// processes, and the same process re-locking the same inode succeeds.
  static Future<InodeLock?> tryAcquire(File path) async {
    final file = await path.open(mode: FileMode.append);
    try {
      await file.lock(); // exclusive is the default mode
      return InodeLock._(file);
    } on FileSystemException catch (error) {
      await file.close();
      // EAGAIN/EWOULDBLOCK — held by another process. Other I/O errors
      // stay red.
      if (const [11, 35].contains(error.osError?.errorCode)) return null;
      rethrow;
    } on Object {
      await file.close();
      rethrow;
    }
  }

  /// Releases the lock. The file itself is left in place.
  Future<void> close() => _file.close();
}
