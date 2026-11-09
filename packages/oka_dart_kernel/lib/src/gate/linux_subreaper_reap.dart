import 'linux_subreaper_reap_stub.dart'
    if (dart.library.ffi) 'linux_subreaper_reap_linux.dart';

/// Non-blocking reap of zombie children (subreaper adoptees). Returns count reaped.
int reapAvailableChildZombies() => reapAvailableChildZombiesImpl();

/// Reap a specific child pid when still a zombie; returns true if reaped.
bool tryReapChildZombie(int pid) => tryReapChildZombieImpl(pid);
