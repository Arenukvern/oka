#!/usr/bin/env bash
# Oka review probes (B3/B4/B5/N1). Run from package root after leader fixes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEADER="$ROOT/tool/owned_session_p1_leader.pl"
FIX="$ROOT/test/fixtures/owned_session_p1"
PROBE_DIR="${P1PROBE_DIR:-/tmp/p1probe/p1probe}"
export LEADER FIX
python3 - "$PROBE_DIR" <<'PY'
import os, socket, subprocess, sys, time, tempfile, signal

PROBE_DIR = sys.argv[1]
LEADER = os.environ["LEADER"]
FIX = os.environ["FIX"]

def start(target, extra=(), marker="m1", restore=True):
    d = tempfile.mkdtemp()
    p = os.path.join(d, "c.sock")
    srv = socket.socket(socket.AF_UNIX)
    srv.bind(p)
    srv.listen(1)
    pr = subprocess.Popen(
        ["/usr/bin/perl", LEADER, "--protocol", "1", "--mode", "owned",
         "--marker", marker, "--control", p, *extra, "--", *target],
        stderr=subprocess.PIPE,
        restore_signals=restore,
    )
    srv.settimeout(5)
    c, _ = srv.accept()
    c.settimeout(10)
    return pr, c

def lines(c, n, timeout=5):
    c.settimeout(timeout)
    buf = b""
    out = []
    try:
        while len(out) < n:
            ch = c.recv(4096)
            if not ch:
                out.append("<EOF>")
                break
            buf += ch
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                out.append(line.decode())
    except socket.timeout:
        out.append("<TIMEOUT>")
    return out

fail = 0

# B3 backtoback
pr, c = start(["sh", "-c", 'trap "" TERM; sleep 3600'])
assert lines(c, 2)[:2] == ["m1", "started"]
time.sleep(0.3)
c.sendall(b"term\nkill\n")
got = lines(c, 3, timeout=3)
if "killed-group" not in got:
    print("FAIL B3 backtoback:", got)
    fail += 1
else:
    print("PASS B3 backtoback")
os.killpg(pr.pid, signal.SIGKILL)

# B4 hookblockskill
pr, c = start(["sleep", "3600"],
              extra=["--graceful", FIX + "/graceful_slow.sh", "--graceful-timeout", "3"])
lines(c, 2)
t = time.time()
c.sendall(b"term\n")
time.sleep(0.2)
c.sendall(b"kill\n")
got = lines(c, 3, timeout=6)
if "killed-group" not in got or time.time() - t > 2.5:
    print("FAIL B4 hookblockskill:", got, "dt", time.time() - t)
    fail += 1
else:
    print("PASS B4 hookblockskill")

# B5 sigpipe
mpath = "/tmp/p1probe_member.pid"
pr, c = start(["sh", "-c", f"sleep 3600 & echo $! > {mpath}; wait"],
              extra=["--graceful", FIX + "/graceful_slow.sh", "--graceful-timeout", "1"],
              restore=False)
lines(c, 2)
time.sleep(0.2)
c.sendall(b"term\n")
c.close()
pr.wait(10)
time.sleep(0.3)
mp = int(open(mpath).read())
try:
    os.kill(mp, 0)
    print("FAIL B5 sigpipe: member still alive", mp)
    os.kill(mp, 9)
    fail += 1
except ProcessLookupError:
    print("PASS B5 sigpipe")

# N1 sigreraise
pr, c = start(["sh", "-c", "sleep 30 & (sleep 0.2; kill -TERM $$) & wait"])
assert lines(c, 2)[:2] == ["m1", "started"]
exit_line = lines(c, 1, timeout=5)[0]
if not exit_line.startswith("exit:"):
    print("FAIL N1 missing exit line:", exit_line)
    fail += 1
c.sendall(b"settle\n")
lines(c, 1)
rc = pr.wait(5)
if rc >= 0:
    print("FAIL N1 sigreraise: leader rc", rc)
    fail += 1
else:
    print("PASS N1 sigreraise rc", rc)

sys.exit(fail)
PY
