# Server live-patch showcase (lane S1, ADR-0035)

A running HTTP server is patched live through the SAME composition API as
the app showcase — one Dart value, one wire, one receipt. The proof of
seamlessness: a client connection opened BEFORE the patch keeps flowing
through it.

```text
== [2/4] start the server (pid printed) + open /stream
server: listening on 8251 pid=92904
  before: hello-v1 pid=92904 uptime=0s
== [3/4] live-patch the server (dart patch_server.dart)
live: [server-vm] applied in 22 ms (reloadKernel)
live: [server-vm] probe `greet()`: hello-v1 -> hello-v2-live
live patch OK — unit `greeter` rev server-v2
== [4/4] continuity + result
  after: hello-v2-live pid=92904 uptime=2s        ← same pid, no restart
  health during-patch window: ok
  stream continuity (ONE connection, old->new without a break):
    stream: hello-v1
    stream[1]: hello-v2-live                       ← same socket
```

## Run it

```bash
./run.sh
```

Same toolchain requirements as `../live_showcase` (pinned checkout,
auto-discovered).

## Lanes

- **S1 (this showcase)** — the server runs JIT (`dart run` + VM service);
  in-memory state survives; sockets survive. For production: loopback +
  tunnel or auth token, never an open port.
- **S2 (registry swap, designed — ADR-0035 §2)** — AOT servers load
  revision-suffixed unit artifacts and flip a registry pointer; needs the
  generator's indirection seam.
- **S3 (`./handoff_demo.sh`)** — snapshot swap with SO_REUSEPORT listener
  handoff. Linux: 60/60 probe connections ok, 0 refused across the swap.
  macOS: dart's `shared:` maps to SO_REUSEADDR, so the demo detects the
  bind failure and reports the platform gap (fd passing stays a gap).
