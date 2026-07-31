#!/usr/bin/env python3
"""G73 fsync/durability kill-9 stress probe.

Runs a SCRATCH DagDB daemon on its OWN unix socket (never the prod
/tmp/dagdb.sock), drives a ~1k ops/s SET-TRUTH write loop under the
group-commit WAL policy, SIGKILLs the daemon mid-write, then restarts it so
it replays the WAL and verifies that recovery lands within the frozen loss
bound (the group-commit N). Also exercises the SHA-256 snapshot manifest end
to end (SAVE writes <snap>.sha256, LOAD verifies it).

kill -9 kills the PROCESS but the OS keeps write()'d-but-unfsync'd bytes, so
the honest expectation is loss == 0 <= N. The bound N is the media-loss
window that only a power cut (which F_FULLFSYNC guards) would actually open;
this probe cannot induce that, and RESULTS.md says so plainly.

Pure stdlib. Every daemon is torn down (SIGKILL) in a finally block.
"""

import os, sys, socket, subprocess, time, random, shutil, tempfile, signal

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DAEMON = os.environ.get("DAGDB_DAEMON", os.path.join(REPO, ".build/release/dagdb-daemon"))
GRID = 64                       # 64x64 = 4096 nodes
WRITES = 1500                   # SET TRUTH ops per iteration
GROUP_N = 64                    # grouped:N — the frozen loss bound
GROUP_MS = 200
ITERATIONS = int(os.environ.get("G73_ITERS", "10"))


def recv_line(sock):
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf.decode(errors="replace").strip()


def cmd(sockpath, line):
    """One command per connection — the daemon reads one line, replies, closes."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sockpath)
    try:
        s.sendall((line + "\n").encode())
        return recv_line(s)
    finally:
        s.close()


def wait_ready(sockpath, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(sockpath):
            try:
                if cmd(sockpath, "STATUS").startswith("OK"):
                    return
            except OSError:
                pass
        time.sleep(0.05)
    raise RuntimeError("daemon never became ready")


def start_daemon(sockpath, walpath, dataroot):
    env = dict(os.environ)
    env["DAGDB_WAL"] = walpath
    env["DAGDB_WAL_FSYNC"] = f"grouped:{GROUP_N}:{GROUP_MS}"
    env["DAGDB_DATA_ROOT"] = dataroot          # legacy path guard; NOT prod
    env.pop("DAGDB_ENV", None)                 # keep grouped policy in effect
    proc = subprocess.Popen(
        [DAEMON, "--grid", str(GRID), "--socket", sockpath, "--shm",
         "/dagdb_g73_" + str(os.getpid())],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc


def hard_kill(proc):
    if proc and proc.poll() is None:
        try:
            proc.send_signal(signal.SIGKILL)
        except OSError:
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            pass


def run_iteration(i):
    workdir = tempfile.mkdtemp(prefix=f"g73_stress_{i}_")
    sockpath = f"/tmp/dagdb_g73_stress_{os.getpid()}_{i}.sock"
    walpath = os.path.join(workdir, "wal.log")
    snappath = os.path.join(workdir, "snap.dags")
    proc = None
    try:
        # ---- phase 1: write then kill -9 mid-write ----
        proc = start_daemon(sockpath, walpath, workdir)
        wait_ready(sockpath)
        kill_after = random.randint(int(WRITES * 0.4), int(WRITES * 0.8))
        acked = 0
        interval = 1.0 / 1000.0     # ~1k ops/s pacing
        for n in range(1, WRITES):
            node = n % (GRID * GRID - 1) + 1
            r = cmd(sockpath, f"SET {node} TRUTH 1")
            if not r.startswith("OK"):
                raise RuntimeError(f"SET failed: {r}")
            acked += 1
            if acked >= kill_after:
                break
            time.sleep(interval)
        hard_kill(proc)             # SIGKILL mid-write

        # ---- phase 2: restart, WAL replays ----
        proc = start_daemon(sockpath, walpath, workdir)
        wait_ready(sockpath)
        survived = 0
        for n in range(1, acked + 1):
            node = n % (GRID * GRID - 1) + 1
            r = cmd(sockpath, f"GET {node} TRUTH")
            # "OK GET node=<node> truth=<v>"
            if r.startswith("OK") and r.strip().endswith("truth=1"):
                survived += 1
        loss = acked - survived

        # ---- phase 3: manifest end-to-end (SAVE writes .sha256, LOAD verifies) ----
        save_r = cmd(sockpath, f"SAVE {snappath}")
        manifest_ok = save_r.startswith("OK") and os.path.exists(snappath + ".sha256")
        load_r = cmd(sockpath, f"LOAD {snappath}")
        load_ok = load_r.startswith("OK")

        within = (0 <= loss <= GROUP_N) and manifest_ok and load_ok
        return {
            "iter": i, "acked": acked, "survived": survived, "loss": loss,
            "bound": GROUP_N, "manifest": manifest_ok, "load": load_ok,
            "pass": within,
        }
    finally:
        hard_kill(proc)
        try:
            os.remove(sockpath)
        except OSError:
            pass
        shutil.rmtree(workdir, ignore_errors=True)


def main():
    if not os.path.exists(DAEMON):
        print(f"FAIL: daemon binary not found at {DAEMON}\n"
              f"      build it first: swift build -c release", file=sys.stderr)
        return 2
    print(f"G73 fsync/durability kill-9 stress probe")
    print(f"  daemon      : {DAEMON}")
    print(f"  grid        : {GRID}x{GRID}  writes/iter: {WRITES}")
    print(f"  wal policy  : grouped:{GROUP_N}:{GROUP_MS}  (loss bound = {GROUP_N})")
    print(f"  iterations  : {ITERATIONS}")
    print()
    header = f"{'iter':>4} {'acked':>6} {'survived':>8} {'loss':>5} {'bound':>5} {'manifest':>8} {'load':>5} {'result':>7}"
    print(header)
    print("-" * len(header))
    all_pass = True
    for i in range(1, ITERATIONS + 1):
        res = run_iteration(i)
        all_pass = all_pass and res["pass"]
        print(f"{res['iter']:>4} {res['acked']:>6} {res['survived']:>8} "
              f"{res['loss']:>5} {res['bound']:>5} "
              f"{str(res['manifest']):>8} {str(res['load']):>5} "
              f"{'PASS' if res['pass'] else 'FAIL':>7}")
    print()
    print(f"RESULT: {'10/10 clean' if all_pass and ITERATIONS==10 else ('ALL PASS' if all_pass else 'FAILURES')}")
    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
