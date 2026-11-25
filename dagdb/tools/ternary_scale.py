#!/usr/bin/env python3
"""ternary_scale.py — the ternary scale checks, driven over the socket.

Every daemon this script starts goes through scripts/start_sandbox.sh with its root under
a scratch run directory (all files under the root, nothing in /tmp). One daemon at a time.
Graphs are built through the bulk verbs: the client frame is written into the daemon's result-row
file (--shm-file), [u32 count][u32 0x314D4800 | the verb's code] at bytes 0..7 (the shm frame,
client_protocol 2) and the vector at offset 8, then the verb is sent.

Subcommands:
  perf  --bin B --root R --side S --kind binary|mixed|ternary --seed X
        build one graph, warm-up TICK 1, then 5 x TICK 100; print startup, RSS, per-run ms.
  r8    --bin B --root R --side S --seed X [--phase all|A|B|C|verdict]
        the scale run: mixed graph via bulk verbs; WAL copy; EXPORT (A0); SAVE (time, size,
        body length); TICK 10; EXPORT (A10). Fresh daemon: LOAD (time); TICK 10; EXPORT (B10).
        Fresh daemon on the WAL copy: replay; EXPORT (C0). Checks: B10 == A10, C0 == A0, body > 4 GiB.
        Each phase is one daemon; phases A, B, C can run as separate invocations (one daemon
        at a time, with a memory check between them);
        their numbers and hashes go to <root>/r8_<side>/state.json, and `verdict` reads them.
  ab    --main M --build B --root R --side S [--pairs 6] [--seed X] [--label L] [--out F]
        The binary-only fast path: paired A/B of two daemons on `perf`'s binary recipe. The graph
        is generated once (gen_binary, the same seed) and sent to every daemon through the same
        bulk verbs; each daemon: start (no WAL), SET_RANKS/LUTS/NEIGHBORS_BULK, TICK 1 (warm-up),
        ONE TICK 100 (the daemon's elapsed=), stop. Pair i runs main and build, main first on even
        i and build first on odd i; right after it a control pair runs main twice (slots A, B, the
        same alternation). Ratio = build / main and, for the control, B / A. Verdict: the median
        build/main ratio <= 1.05, with the control's median and range printed beside it. The
        idle-GPU rule is replaced by this interleaving under the shared background;
        the GPU's utilization is sampled before each pair and printed, not gated.

Memory guard (the machine's rule): before a daemon of >= 50M nodes starts, free + inactive +
speculative memory from vm_stat must be >= 40 GiB (rechecked every 5 min, at most 6 times, then
the run refuses); --pre-wait S sleeps S seconds before that check. While a daemon runs, a sampler
records its peak RSS, this driver's peak RSS and the lowest available memory; if available memory
falls below the floor (6 GiB) the daemon is stopped and the run aborts. The sampler is paused
during the timed TICK runs of `perf`, so the speed runs are taken under the baseline measurement's
conditions.

Literals from the scale measurement's definition: ranks 0..63; 5 runs x 100 ticks (the speed check);
10 ticks (the SAVE/LOAD exactness check); 1/3 binary, 1/3 TTABLE, 1/3 TTHRESH. The rest are this script's own definitional choices,
named where they are made.
"""
import argparse, errno, hashlib, json, mmap, os, re, signal, socket, statistics, struct, subprocess, sys, threading, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SANDBOX = os.path.join(HERE, "..", "scripts", "start_sandbox.sh")
RANK_LEVELS = 64            # the scale measurement's definition: ranks 0..63
RUNS, TICKS_PER_RUN = 5, 100  # the speed check: median of 5 runs x 100 ticks
R8_TICKS = 10               # the SAVE/LOAD exactness check: 10 ticks
ABSENT_ONE_IN = 4           # one slot in four is empty (definitional)
LIB_TABLES = 64             # library size for the mixed graph (definitional)
STARTUP_WAIT_S = 600        # how long to wait for a 100M daemon's socket
GIB = 1 << 30
MEM_GATE_NODES = 50_000_000 # the memory gate applies to daemons this large (the 100M runs)
MEM_NEED = 40 * GIB         # the machine's rule: >= 40 GB free+inactive+speculative (GiB: the stricter reading)
MEM_RECHECK_S, MEM_RECHECKS = 300, 6   # the machine's rule: wait 5 min, re-check up to 6 times
MEM_FLOOR = 6 * GIB         # abort a running daemon below this (definitional safety valve)
MEM_WARN = 20 * 10**9       # below ~20 GB available, print a warning (the operator tells the other session)
AB_PAIRS = 6                # the paired speed comparison: at least 5 interleaved pairs per size; 6 balances the alternating order 3/3
AB_LIMIT = 1.05             # the paired speed comparison: median pair ratio (build / main) <= 1.05


def now():
    return time.strftime("%Y-%m-%d %H:%M:%S %Z")


def mem_avail():
    """free + inactive + speculative bytes from vm_stat, with the page size its header prints."""
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    page = int(re.search(r"page size of (\d+) bytes", out).group(1))
    pages = {k: int(re.search(rf"Pages {k}:\s+(\d+)\.", out).group(1)) for k in ("free", "inactive", "speculative")}
    return page * sum(pages.values()), page, pages


def mem_gate(n, label):
    """The machine's rule: before a >= 50M daemon starts, require MEM_NEED available; else wait and re-check."""
    if n < MEM_GATE_NODES:
        return None
    for attempt in range(MEM_RECHECKS + 1):
        avail, page, pages = mem_avail()
        print(f"[{now()}] memory gate ({label}): free {pages['free']} + inactive {pages['inactive']} + "
              f"speculative {pages['speculative']} pages x {page} B = {avail / GIB:.1f} GiB "
              f"({avail / 1e9:.1f} GB); need {MEM_NEED / GIB:.0f} GiB", flush=True)
        if avail >= MEM_NEED:
            return avail
        if attempt < MEM_RECHECKS:
            print(f"[{now()}] memory gate: below the need, waiting {MEM_RECHECK_S} s (re-check {attempt + 1}/{MEM_RECHECKS})", flush=True)
            time.sleep(MEM_RECHECK_S)
    raise SystemExit(f"REFUSED: memory gate ({label}): {avail / GIB:.1f} GiB < {MEM_NEED / GIB:.0f} GiB after {MEM_RECHECKS} re-checks")


GPU_QUIET_PCT = 10          # measurement condition: others' GPU device utilization <= 10% ...
GPU_QUIET_SAMPLES = 10      # ... in each of 10 one-second samples (the baseline measurement ran on an idle GPU)


def gpu_util():
    """Device utilization % of the GPU (IOAccelerator), over every process."""
    out = subprocess.run(["ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"],
                         capture_output=True, text=True).stdout
    m = re.findall(r'"Device Utilization %"=(\d+)', out)
    return max(int(x) for x in m) if m else None


def gpu_samples(k=GPU_QUIET_SAMPLES):
    v = []
    for i in range(k):
        v.append(gpu_util())
        if i + 1 < k:
            time.sleep(1.0)
    return v


def wait_gpu_quiet(max_wait_s, label, period_s=60):
    """Poll until GPU_QUIET_SAMPLES consecutive samples are <= GPU_QUIET_PCT, or give up."""
    t0 = time.time()
    while True:
        v = gpu_samples()
        quiet = all(x is not None and x <= GPU_QUIET_PCT for x in v)
        print(f"[{now()}] gpu ({label}): {v} -> {'QUIET' if quiet else 'busy'}", flush=True)
        if quiet:
            return v
        if time.time() - t0 + period_s > max_wait_s:
            return None
        time.sleep(period_s)


def rss_of(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    return int(out.strip()) * 1024 if out.strip() else None


class MemWatch(threading.Thread):
    """Samples the daemon's RSS, this driver's RSS and available memory once a second."""

    def __init__(self, daemon, period=1.0):
        super().__init__(daemon=True)
        self.d, self.period = daemon, period
        self.peak_daemon = 0
        self.peak_self = 0
        self.min_avail = None
        self.paused = threading.Event()
        self.halt = threading.Event()
        self.tripped = None

    def run(self):
        while not self.halt.is_set():
            if not self.paused.is_set():
                try:
                    r = rss_of(self.d.pid) if self.d.pid else None
                    if r:
                        self.peak_daemon = max(self.peak_daemon, r)
                    s = rss_of(os.getpid())
                    if s:
                        self.peak_self = max(self.peak_self, s)
                    avail, _, _ = mem_avail()
                    self.min_avail = avail if self.min_avail is None else min(self.min_avail, avail)
                    if avail < MEM_WARN and not getattr(self, "warned", False):
                        self.warned = True
                        print(f"[{now()}] LOW MEMORY WARNING: available {avail / 1e9:.1f} GB < {MEM_WARN / 1e9:.0f} GB", flush=True)
                    if avail < MEM_FLOOR and self.tripped is None:
                        self.tripped = f"available memory {avail / GIB:.1f} GiB < floor {MEM_FLOOR / GIB:.0f} GiB at {now()}"
                        print(f"[{now()}] MEMORY FLOOR: {self.tripped} — stopping the daemon", flush=True)
                        try:
                            os.kill(self.d.pid, signal.SIGTERM)
                            time.sleep(10)
                            if pid_alive(self.d.pid):
                                os.kill(self.d.pid, signal.SIGKILL)
                        except OSError:
                            pass
                except Exception as e:  # a sampler hiccup must not kill the run
                    print(f"[{now()}] memwatch: {e}", flush=True)
            self.halt.wait(self.period)

    def summary(self):
        return dict(peak_daemon_rss_mb=round(self.peak_daemon / 2**20),
                    peak_driver_rss_mb=round(self.peak_self / 2**20),
                    min_avail_gib=round(self.min_avail / GIB, 1) if self.min_avail is not None else None,
                    floor_tripped=self.tripped)


class Daemon:
    def __init__(self, binary, root, side, max_rank=RANK_LEVELS, wal=True):
        self.bin, self.root, self.side, self.max_rank, self.wal = binary, root, side, max_rank, wal
        self.sock = os.path.join(root, "dagdb.sock")
        self.shm_path = os.path.join(root, "dagdb_shm")
        self.n = side * side
        self.pid = None
        self.startup_s = None

    def start(self, pre_wait=0, label="daemon"):
        if pre_wait:
            print(f"[{now()}] pre-wait {pre_wait} s before starting {label} ({self.n} nodes)", flush=True)
            time.sleep(pre_wait)
        self.mem_at_start = mem_gate(self.n, label)
        # One daemon at a time (the machine's rule): only daemons outside this run's tree may be up.
        mine = [l for l in daemon_lines() if "000_bloat/runs/ternary" in l]
        if mine:
            raise SystemExit(f"REFUSED: a daemon of this run is still up: {mine}")
        os.makedirs(self.root, exist_ok=True)
        env = dict(os.environ)
        env["DAGDB_DAEMON_BIN"] = self.bin
        env["DAGDB_SANDBOX_WAL"] = "on" if self.wal else "off"
        t0 = time.time()
        # start_sandbox.sh waits 20 s for the socket; a 100M daemon may need longer, so a
        # non-zero exit 6 ("did not open its socket") is tolerated here and the socket polled.
        pidf = os.path.join(self.root, "daemon.pid")
        if os.path.exists(pidf):  # a stale pid file must not be mistaken for the new daemon
            try:
                stale = int(open(pidf).read().strip())
            except ValueError:
                stale = None
            if stale is not None and pid_alive(stale):
                raise SystemExit(f"REFUSED: a daemon is already running for this root (pid {stale})")
            os.remove(pidf)
        p = subprocess.Popen(["zsh", SANDBOX, self.root, str(self.side), str(self.max_rank)],
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        # Sample from the first moment the pid exists: a startup WAL replay or a large
        # allocation happens before the socket opens (start_sandbox.sh waits for the socket).
        self.watch = None
        while p.poll() is None:
            if self.watch is None and os.path.exists(pidf):
                try:
                    self.pid = int(open(pidf).read().strip())
                    self.watch = MemWatch(self)
                    self.watch.start()
                except ValueError:
                    pass
            time.sleep(0.05)
        so, se = p.communicate()
        if p.returncode not in (0, 6) or not os.path.exists(pidf):
            raise SystemExit(f"start_sandbox failed rc={p.returncode}: {so} {se}")
        self.pid = int(open(pidf).read().strip())
        if self.watch is None:
            self.watch = MemWatch(self)
            self.watch.start()
        deadline = t0 + STARTUP_WAIT_S
        while time.time() < deadline:
            if os.path.exists(self.sock):
                try:
                    r = self.cmd("STATUS", timeout=30)
                    if r.startswith("OK STATUS"):
                        break
                except OSError:
                    pass
            if not pid_alive(self.pid):
                raise SystemExit("daemon died during startup; see " + os.path.join(self.root, "daemon.log"))
            time.sleep(0.25)
        else:
            raise SystemExit("daemon socket never answered")
        self.startup_s = time.time() - t0
        # The stale-binary check start_sandbox.sh skips on its exit 6: the result file must be ours.
        log = open(os.path.join(self.root, "daemon.log")).read()
        if f"at {self.shm_path}" not in log or not os.path.exists(self.shm_path):
            self.stop()
            raise SystemExit("REFUSED: the daemon did not put its result file under the root")
        return self

    def cmd(self, line, timeout=3600):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(self.sock)
        s.sendall((line.strip() + "\n").encode())
        # The daemon stops reading at the newline, answers and closes; when it
        # closes first, macOS reports ENOTCONN here although the whole reply is
        # waiting in the socket.
        try:
            s.shutdown(socket.SHUT_WR)
        except OSError as e:
            if e.errno != errno.ENOTCONN:
                raise
        out = b""
        while True:
            c = s.recv(65536)
            if not c:
                break
            out += c
        s.close()
        return out.decode().strip()

    def must(self, line, timeout=3600):
        r = self.cmd(line, timeout=timeout)
        if not r.startswith("OK"):
            raise SystemExit(f"FAIL: {line!r} -> {r}")
        return r

    def rss_mb(self):
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(self.pid)], capture_output=True, text=True).stdout
        return int(out.strip()) / 1024.0 if out.strip() else float("nan")

    def shm(self):
        f = open(self.shm_path, "r+b")
        m = mmap.mmap(f.fileno(), 0)
        f.close()
        return m

    def write_shm(self, arr, count, verb):
        """A client frame (client_protocol 2): [u32 count][u32 0x314D4800 | the verb's code]
        at bytes 0..7, the vector from 8. count in the verb's unit (nodes, or tables for TTABLE_BULK).
        A daemon before client_protocol 2 reads none of these eight bytes for these verbs, so the frame
        serves both (the ab subcommand's main daemon). The verb codes, restated here."""
        code = {"SET_RANKS_BULK": 1, "SET_LUTS_BULK": 2, "SET_NEIGHBORS_BULK": 3, "SET_MODES_BULK": 4,
                "SET_TTABLE_IDS_BULK": 5, "SET_THRESH_BULK": 6, "TTABLE_BULK": 7}[verb]
        b = memoryview(np.ascontiguousarray(arr)).cast("B")
        m = self.shm()
        if 8 + len(b) > len(m):
            raise SystemExit(f"vector of {len(b)} bytes does not fit shm {len(m)}")
        m[0:8] = struct.pack("<II", count, 0x314D4800 | code)
        m[8:8 + len(b)] = b
        m.flush()
        m.close()

    def stop(self):
        subprocess.run(["zsh", SANDBOX, self.root, "stop"], capture_output=True, text=True)
        for _ in range(2400):
            if not pid_alive(self.pid):
                break
            time.sleep(0.25)
        if pid_alive(self.pid):
            raise SystemExit(f"REFUSED: daemon {self.pid} still alive 600 s after stop")
        w = getattr(self, "watch", None)
        if w is not None:
            w.halt.set()
            w.join(timeout=5)
            self.mem = w.summary()
            print(f"[{now()}] stopped pid {self.pid}; memory: {self.mem}", flush=True)
            if w.tripped:
                raise SystemExit("ABORTED: " + w.tripped)
        assert_tmp_clean()


def daemon_lines():
    """Running dagdb-daemon processes (by process name, not by command-line text)."""
    pids = subprocess.run(["pgrep", "-x", "dagdb-daemon"], capture_output=True, text=True).stdout.split()
    out = []
    for p in pids:
        a = subprocess.run(["ps", "-o", "args=", "-p", p], capture_output=True, text=True).stdout.strip()
        if a:
            out.append(f"{p} {a}")
    return out


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def assert_tmp_clean():
    left = [f for f in os.listdir("/tmp") if "dagdb" in f]
    if left:
        raise SystemExit(f"REFUSED: /tmp holds dagdb files after a daemon run: {left}")


# ── graph generation (numpy, seeded) ─────────────────────────────────────────

def gen_binary(n, seed):
    rng = np.random.Generator(np.random.PCG64(seed))
    ranks = rng.integers(0, RANK_LEVELS, size=n, dtype=np.uint64)
    luts = np.frombuffer(rng.bytes(8 * n), dtype=np.uint64)
    order = np.argsort(ranks, kind="stable").astype(np.int32)
    counts = np.bincount(ranks.astype(np.int64), minlength=RANK_LEVELS + 1)
    start = np.concatenate([[0], np.cumsum(counts)]).astype(np.int64)
    lo = start[ranks.astype(np.int64) + 1]
    span = n - lo
    nb = np.full((n, 6), -1, dtype=np.int32)
    for d in range(6):
        u = rng.random(n)
        absent = rng.integers(0, ABSENT_ONE_IN, size=n) == 0
        idx = lo + np.minimum((u * span).astype(np.int64), np.maximum(span - 1, 0))
        idx = np.minimum(idx, n - 1)
        col = order[idx]
        col[absent | (span == 0)] = -1
        nb[:, d] = col
        del u, absent, idx, col
    # duplicates within a row become empty (VALIDATE and LOAD refuse duplicate edges)
    for j in range(1, 6):
        for k in range(j):
            dup = (nb[:, j] == nb[:, k]) & (nb[:, j] >= 0)
            nb[dup, j] = -1
    return ranks, luts, nb, rng


def tern_table(rng):
    return rng.integers(0, 3, size=729, dtype=np.uint8)


def gen_lanes(n, rng, kind):
    """mode, ttableId, thrLo/thrHi, library for kind in {binary, mixed, ternary}."""
    if kind == "binary":
        return None
    if kind == "mixed":
        k = rng.integers(0, 3, size=n, dtype=np.uint8)          # 0 BINARY, 1 TTABLE, 2 TTHRESH
    else:
        k = rng.integers(1, 3, size=n, dtype=np.uint8)          # TTABLE or TTHRESH only
    noskip = (rng.integers(0, 2, size=n, dtype=np.uint8) * 4) * (k != 0)
    mode = (k | noskip).astype(np.uint8)
    tid = rng.integers(0, LIB_TABLES, size=n, dtype=np.uint16)
    # thresholds: lo <= hi, finite; s is a sum of up to six weights of 1.0 (default lane)
    a = rng.integers(-6, 7, size=n).astype(np.float32) / 2
    b = rng.integers(-6, 7, size=n).astype(np.float32) / 2
    lo, hi = np.minimum(a, b), np.maximum(a, b)
    thr = np.empty(2 * n, dtype=np.float32)
    thr[0::2], thr[1::2] = lo, hi
    lib = np.stack([tern_table(rng) for _ in range(LIB_TABLES)])
    return mode, tid, thr, lib


def build(d, kind, seed):
    n = d.n
    t0 = time.time()
    ranks, luts, nb, rng = gen_binary(n, seed)
    lanes = gen_lanes(n, rng, kind)
    tgen = time.time() - t0
    t0 = time.time()
    info = dict(present_slots=int((nb >= 0).sum()))
    d.write_shm(ranks, d.n, "SET_RANKS_BULK"); d.must("SET_RANKS_BULK")
    d.write_shm(luts, d.n, "SET_LUTS_BULK"); d.must("SET_LUTS_BULK")
    d.write_shm(nb, d.n, "SET_NEIGHBORS_BULK"); d.must("SET_NEIGHBORS_BULK")
    del ranks, luts, nb
    if lanes is not None:
        mode, tid, thr, lib = lanes
        kinds = np.bincount(mode & 3, minlength=3)
        info.update(binary=int(kinds[0]), ttable=int(kinds[1]), tthresh=int(kinds[2]),
                    noskip=int(((mode & 4) != 0).sum()), tables=LIB_TABLES)
        d.write_shm(lib, LIB_TABLES, "TTABLE_BULK"); d.must(f"TTABLE_BULK 0 {LIB_TABLES}")
        d.write_shm(tid, d.n, "SET_TTABLE_IDS_BULK"); d.must("SET_TTABLE_IDS_BULK")
        d.write_shm(thr, d.n, "SET_THRESH_BULK"); d.must("SET_THRESH_BULK")
        d.write_shm(mode, d.n, "SET_MODES_BULK"); info["modes_reply"] = d.must("SET_MODES_BULK")
        del mode, tid, thr, lib
    del lanes
    return tgen, time.time() - t0, info


def parse_ms(reply):
    for tok in reply.split():
        if tok.startswith("elapsed="):
            return float(tok[len("elapsed="):].rstrip("ms"))
    raise SystemExit("no elapsed= in " + reply)


def perf(args):
    root = os.path.join(args.root, f"perf_{args.label}_{args.kind}_{args.side}")
    gpu_before_start = None
    if args.quiet_wait:
        gpu_before_start = wait_gpu_quiet(args.quiet_wait * 60, "before start")
        if gpu_before_start is None:
            print(f"[{now()}] NOT READ: the GPU did not go quiet within {args.quiet_wait} min; no daemon started", flush=True)
            raise SystemExit(3)
    # Timing runs need no replay: no WAL (a 100M bulk vector is a 2.4 GB record).
    d = Daemon(args.bin, root, args.side, wal=False).start(pre_wait=args.pre_wait, label=f"perf {args.kind} {args.side}")
    print(f"[{now()}] {args.label} {args.kind} side={args.side} nodes={d.n} startup={d.startup_s:.1f}s rss={d.rss_mb():.0f}MB", flush=True)
    try:
        tgen, tbuild, info = build(d, args.kind, args.seed)
        rss_built = d.rss_mb()
        print(f"[{now()}] built: generate {tgen:.1f}s, bulk verbs {tbuild:.1f}s, rss={rss_built:.0f}MB, {info}", flush=True)
        # Quiet check right before the timed runs (the measurement rule): daemons, load, top CPU.
        quiet = daemon_lines()
        print(f"[{now()}] daemons running: {len(quiet)} (this one + others): " + " | ".join(l[:90] for l in quiet), flush=True)
        top = subprocess.run(["ps", "-Ao", "pcpu=,comm=", "-r"], capture_output=True, text=True).stdout.strip().splitlines()[:6]
        print(f"[{now()}] loadavg={os.getloadavg()} top cpu: " + " | ".join(" ".join(t.split()) [:70] for t in top), flush=True)
        gpu_before_runs = gpu_samples()   # the daemon is idle here: this is everyone else's GPU load
        print(f"[{now()}] gpu before the timed runs: {gpu_before_runs}", flush=True)
        if args.quiet_wait and not all(x is not None and x <= GPU_QUIET_PCT for x in gpu_before_runs):
            gpu_before_runs = wait_gpu_quiet(600, "built, before the timed runs", period_s=30)
            if gpu_before_runs is None:
                print(f"[{now()}] NOT READ: the GPU went busy after the build and stayed busy 10 min", flush=True)
                raise SystemExit(3)
        d.watch.paused.set()   # nothing but the daemon during the timed runs (as in the baseline measurement)
        d.must("TICK 1")  # warm-up: the first tick rebuilds the compacted dispatch (O(N) CPU pass)
        runs = []
        for i in range(RUNS):
            r = d.must(f"TICK {TICKS_PER_RUN}")
            ms = parse_ms(r)
            runs.append(ms)
            print(f"  run {i + 1}: TICK {TICKS_PER_RUN} elapsed={ms:.2f}ms ({ms / TICKS_PER_RUN:.3f} ms/tick)", flush=True)
        d.watch.paused.clear()
        gpu_after_runs = gpu_samples(5)
        print(f"[{now()}] gpu after the timed runs: {gpu_after_runs}", flush=True)
        med = statistics.median(runs)
        rss = d.rss_mb()
    finally:
        d.stop()
    for f in ("dagdb.wal", "dagdb_shm"):
        p = os.path.join(root, f)
        if os.path.exists(p):
            os.remove(p)
    res = dict(label=args.label, kind=args.kind, side=args.side, nodes=args.side * args.side,
               startup_s=round(d.startup_s, 2), rss_mb=round(rss), rss_built_mb=round(rss_built),
               runs_ms=runs, median_ms=med, median_ms_per_tick=med / TICKS_PER_RUN,
               generate_s=round(tgen, 1), bulk_verbs_s=round(tbuild, 1), graph=info,
               mem_at_start_gib=round(d.mem_at_start / GIB, 1) if d.mem_at_start else None,
               memory=d.mem, gpu_before_start=gpu_before_start, gpu_before_runs=gpu_before_runs,
               gpu_after_runs=gpu_after_runs, quiet_rule=bool(args.quiet_wait), when=now())
    print("RESULT " + json.dumps(res), flush=True)
    if args.out:
        with open(args.out, "a") as fh:
            fh.write(json.dumps(res) + "\n")


def bin_identity(path):
    st = os.stat(path)
    return dict(path=path, bytes=st.st_size, mtime=time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(st.st_mtime)))


def ab_run_one(binary, root, side, arrays, label):
    """One daemon of an A/B pair: `perf`'s binary recipe through the bulk verbs (no WAL), the
    warm-up TICK 1, then ONE TICK 100 timed by the daemon (elapsed=)."""
    d = Daemon(binary, root, side, wal=False).start(label=label)
    try:
        ranks, luts, nb = arrays
        t0 = time.time()
        d.write_shm(ranks, d.n, "SET_RANKS_BULK"); d.must("SET_RANKS_BULK")
        d.write_shm(luts, d.n, "SET_LUTS_BULK"); d.must("SET_LUTS_BULK")
        d.write_shm(nb, d.n, "SET_NEIGHBORS_BULK"); d.must("SET_NEIGHBORS_BULK")
        tbuild = time.time() - t0
        rss = d.rss_mb()
        gpu = gpu_util()                 # one sample, daemon idle: everyone else's load (printed only)
        d.watch.paused.set()             # nothing but the daemon during the timed run (as in perf)
        d.must("TICK 1")                 # warm-up: the first tick rebuilds the compacted dispatch
        r = d.must(f"TICK {TICKS_PER_RUN}")
        d.watch.paused.clear()
        ms = parse_ms(r)
    finally:
        d.stop()
    for f in ("dagdb.wal", "dagdb_shm"):
        p = os.path.join(root, f)
        if os.path.exists(p):
            os.remove(p)
    return dict(label=label, ms=ms, startup_s=round(d.startup_s, 2), bulk_verbs_s=round(tbuild, 1),
                rss_mb=round(rss), gpu_before_tick=gpu, min_avail_gib=d.mem.get("min_avail_gib"), when=now())


def ab(args):
    n = args.side * args.side
    base = os.path.join(args.root, f"ab_{args.label}_{args.side}")
    os.makedirs(base, exist_ok=True)
    ids = dict(main=bin_identity(args.main), build=bin_identity(args.build))
    print(f"[{now()}] ab {args.label} side={args.side} nodes={n} pairs={args.pairs} seed={args.seed:#x}", flush=True)
    print(f"[{now()}] main  = {ids['main']}", flush=True)
    print(f"[{now()}] build = {ids['build']}", flush=True)
    t0 = time.time()
    ranks, luts, nb, _ = gen_binary(n, args.seed)
    arrays = (ranks, luts, nb)
    h = hashlib.sha256()
    for x in arrays:
        h.update(memoryview(np.ascontiguousarray(x)).cast("B"))
    ghash = h.hexdigest()
    print(f"[{now()}] graph generated once in {time.time() - t0:.1f}s: present slots {int((nb >= 0).sum())}, "
          f"arrays sha256 {ghash[:16]}", flush=True)
    pairs = []
    for i in range(args.pairs):
        gpu = gpu_samples(5)
        print(f"[{now()}] pair {i + 1}: gpu before {gpu}, loadavg {os.getloadavg()}", flush=True)
        test = [("main", args.main), ("build", args.build)]
        ctl = [("A", args.main), ("B", args.main)]
        if i % 2 == 1:
            test.reverse(); ctl.reverse()
        res = {}
        for lab, b in test:
            res[lab] = ab_run_one(b, os.path.join(base, f"p{i + 1}_{lab}"), args.side, arrays, f"ab {lab} p{i + 1}")
            print(f"  pair {i + 1} {lab:5s}: TICK {TICKS_PER_RUN} elapsed={res[lab]['ms']:.2f}ms", flush=True)
        ctl_res = {}
        for lab, b in ctl:
            ctl_res[lab] = ab_run_one(b, os.path.join(base, f"p{i + 1}_ctl{lab}"), args.side, arrays, f"ab control {lab} p{i + 1}")
            print(f"  pair {i + 1} ctl {lab}: TICK {TICKS_PER_RUN} elapsed={ctl_res[lab]['ms']:.2f}ms (main)", flush=True)
        rec = dict(label=args.label, side=args.side, nodes=n, pair=i + 1, order=[t[0] for t in test],
                   ctl_order=[c[0] for c in ctl], gpu_before=gpu, graph_sha256=ghash,
                   main=res["main"], build=res["build"], ctlA=ctl_res["A"], ctlB=ctl_res["B"],
                   ratio=res["build"]["ms"] / res["main"]["ms"], ctl_ratio=ctl_res["B"]["ms"] / ctl_res["A"]["ms"])
        pairs.append(rec)
        print(f"PAIR {i + 1}: build/main = {rec['ratio']:.4f}   control B/A = {rec['ctl_ratio']:.4f}", flush=True)
        if args.out:
            with open(args.out, "a") as fh:
                fh.write(json.dumps(dict(binaries=ids, **rec)) + "\n")
    rs = [p["ratio"] for p in pairs]
    cs = [p["ctl_ratio"] for p in pairs]
    med, cmed = statistics.median(rs), statistics.median(cs)
    print(f"\nR8(d) A/B, side {args.side} ({n} nodes), {args.label}: TICK {TICKS_PER_RUN} ms per daemon, "
          f"pairs interleaved, order alternating", flush=True)
    print(f"  pair | first | main ms   | build ms  | build/main || ctl A ms  | ctl B ms  | B/A", flush=True)
    for p in pairs:
        print(f"  {p['pair']:4d} | {p['order'][0]:5s} | {p['main']['ms']:9.2f} | {p['build']['ms']:9.2f} | "
              f"{p['ratio']:10.4f} || {p['ctlA']['ms']:9.2f} | {p['ctlB']['ms']:9.2f} | {p['ctl_ratio']:.4f}", flush=True)
    verdict = "PASS" if med <= AB_LIMIT else "FAIL"
    print(f"R8(d) {args.label} side={args.side}: median build/main {med:.4f} (range {min(rs):.4f}-{max(rs):.4f}, "
          f"{(med - 1) * 100:+.2f}%) <= {AB_LIMIT} -> {verdict}; control main/main median {cmed:.4f} "
          f"(range {min(cs):.4f}-{max(cs):.4f})", flush=True)
    summ = dict(summary=True, label=args.label, side=args.side, nodes=n, pairs=len(pairs), median_ratio=med,
                ratio_range=[min(rs), max(rs)], ctl_median=cmed, ctl_range=[min(cs), max(cs)],
                limit=AB_LIMIT, verdict=verdict, binaries=ids, graph_sha256=ghash, when=now())
    print("RESULT " + json.dumps(summ), flush=True)
    if args.out:
        with open(args.out, "a") as fh:
            fh.write(json.dumps(summ) + "\n")


def export_hash(d, label, keep_truth=False):
    """EXPORT MORTON into the daemon's root (a raw dump of every engine lane, the back-edge list
    and the library, 16 files), hash every file (name-sorted), delete them.
    Returns (combined hex, {file: hex}, total bytes, reply, truth array or None)."""
    sub = os.path.join(d.root, "exp_" + label)
    r = d.must(f"EXPORT MORTON {sub}")
    per, total = {}, 0
    combined = hashlib.sha256()
    truth = None
    for name in sorted(os.listdir(sub)):
        h = hashlib.sha256()
        p = os.path.join(sub, name)
        with open(p, "rb") as fh:
            while True:
                b = fh.read(1 << 26)
                if not b:
                    break
                h.update(b)
        per[name] = h.hexdigest()
        total += os.path.getsize(p)
        combined.update(name.encode() + b"\0" + bytes.fromhex(per[name]))
        if keep_truth and name == "truth.bin":
            truth = np.fromfile(p, dtype=np.uint8)
        os.remove(p)
    os.rmdir(sub)
    print(f"[{now()}] export {label}: {len(per)} files, {total} bytes, {r.split('elapsed=')[1].split()[0] if 'elapsed=' in r else r}", flush=True)
    return combined.hexdigest(), per, total, r, truth


def dags_header(path):
    with open(path, "rb") as f:
        h = f.read(40)
    magic, ver, nc, gw, gh, ticks, flags, bb = struct.unpack("<4sIIIIIII", h[:32])
    body = struct.unpack("<Q", h[32:40])[0] if bb == 0xFFFFFFFF else bb
    return dict(magic=magic.decode("latin-1"), version=ver, nodes=nc, gridW=gw, gridH=gh, ticks=ticks,
                flags=flags, bodyBytes28=bb, body_len=body)


def trit_counts(truth, n):
    """Truth-byte histogram summary: 0, 1, 2, >= 3."""
    c = np.bincount(truth, minlength=256)
    return dict(b0=int(c[0]), b1=int(c[1]), b2=int(c[2]), loom=int(c[3:].sum()))


def r8_paths(args):
    base = os.path.join(args.root, f"r8_{args.side}")
    return base, os.path.join(base, "A"), os.path.join(base, "B"), os.path.join(base, "C"), os.path.join(base, "state.json")


def r8_state(path, update=None):
    st = json.load(open(path)) if os.path.exists(path) else {}
    if update:
        st.update(update)
        with open(path + ".tmp", "w") as fh:
            json.dump(st, fh, indent=1)
        os.replace(path + ".tmp", path)
    return st


def clean_dir(r):
    os.makedirs(r, exist_ok=True)
    for f in os.listdir(r):
        fp = os.path.join(r, f)
        if os.path.isfile(fp) or os.path.islink(fp):
            os.remove(fp)


def r8_phase_a(args):
    base, ra, rb, rc, stp = r8_paths(args)
    for r in (ra, rb, rc):
        clean_dir(r)
    if os.path.exists(stp):
        os.remove(stp)
    out = {"seed": args.seed, "side": args.side, "nodes": args.side * args.side, "A_begin": now()}
    # ── A: build through the bulk verbs, WAL on ──
    a = Daemon(args.bin, ra, args.side).start(pre_wait=args.pre_wait, label="r8 A (build, SAVE)")
    out["A_mem_at_start_gib"] = round(a.mem_at_start / GIB, 1) if a.mem_at_start else None
    out["A_startup_s"], out["A_rss_after_start_mb"] = round(a.startup_s, 2), round(a.rss_mb())
    try:
        tgen, tbuild, info = build(a, "mixed", args.seed)
        out["generate_s"], out["bulk_verbs_s"], out["A_rss_built_mb"] = round(tgen, 1), round(tbuild, 1), round(a.rss_mb())
        out["graph"] = info
        print(f"[{now()}] A built: {out}", flush=True)
        wal_a = os.path.join(ra, "dagdb.wal")
        a.must("STATUS")  # the bulk session is complete in the log before it is copied
        out["wal_bytes"] = os.path.getsize(wal_a)
        t0 = time.time()
        subprocess.run(["cp", wal_a, os.path.join(rc, "dagdb.wal")], check=True)
        out["wal_copy_s"] = round(time.time() - t0, 1)
        out["graph_info_A0"] = a.must("GRAPH INFO").split("ternary_nodes=")[-1]
        hA0, perA0, bytesA0, _, truthA0 = export_hash(a, "A0", keep_truth=True)
        out["truth_A0"] = trit_counts(truthA0, a.n)
        snap = os.path.join(ra, "graph.dags")
        r = a.must(f"SAVE {snap}")
        out["save_reply"] = r
        out["save_ms"] = float(r.split("elapsed=")[1].split("ms")[0])
        out["save_bytes"] = os.path.getsize(snap)
        out["header"] = dags_header(snap)
        r = a.must(f"TICK {R8_TICKS}")
        out["A_tick10_reply"] = r
        out["graph_info_A10"] = a.must("GRAPH INFO").split("ternary_nodes=")[-1]
        hA10, perA10, _, _, truthA10 = export_hash(a, "A10", keep_truth=True)
        out["truth_A10"] = trit_counts(truthA10, a.n)
        out["truth_bytes_changed_by_10_ticks"] = int((truthA0 != truthA10).sum())
        del truthA0, truthA10
        out["A_rss_end_mb"] = round(a.rss_mb())
    finally:
        a.stop()
    out["A_memory"] = a.mem
    os.remove(wal_a)
    for f in ("graph.dags", "graph.dags.sha256"):
        os.replace(os.path.join(ra, f), os.path.join(rb, f))
    out.update(hash_A0=hA0, hash_A10=hA10, files_A0=perA0, files_A10=perA10, export_bytes=bytesA0, A_end=now())
    r8_state(stp, out)
    print(f"[{now()}] A done: save {out['save_ms']} ms, {out['save_bytes']} bytes, header {out['header']}", flush=True)


def r8_phase_b(args):
    base, ra, rb, rc, stp = r8_paths(args)
    st = r8_state(stp)
    if "hash_A10" not in st:
        raise SystemExit("phase B needs phase A's state")
    out = {"B_begin": now()}
    snap = os.path.join(rb, "graph.dags")
    b = Daemon(args.bin, rb, args.side).start(pre_wait=args.pre_wait, label="r8 B (LOAD)")
    out["B_mem_at_start_gib"] = round(b.mem_at_start / GIB, 1) if b.mem_at_start else None
    out["B_startup_s"] = round(b.startup_s, 2)
    try:
        r = b.must(f"LOAD {snap}")
        out["load_reply"] = r
        out["load_ms"] = float(r.split("elapsed=")[1].split("ms")[0])
        out["B_rss_after_load_mb"] = round(b.rss_mb())
        hB0, perB0, _, _, _ = export_hash(b, "B0")
        out["B_tick10_reply"] = b.must(f"TICK {R8_TICKS}")
        out["graph_info_B10"] = b.must("GRAPH INFO").split("ternary_nodes=")[-1]
        hB10, perB10, _, _, _ = export_hash(b, "B10")
        out["B_rss_end_mb"] = round(b.rss_mb())
    finally:
        b.stop()
    out["B_memory"] = b.mem
    for f in ("graph.dags", "graph.dags.sha256", "dagdb.wal"):
        p = os.path.join(rb, f)
        if os.path.exists(p):
            os.remove(p)
    out.update(hash_B0=hB0, hash_B10=hB10, files_B0=perB0, files_B10=perB10, B_end=now())
    r8_state(stp, out)


def r8_phase_c(args):
    base, ra, rb, rc, stp = r8_paths(args)
    st = r8_state(stp)
    if "hash_A0" not in st or not os.path.exists(os.path.join(rc, "dagdb.wal")):
        raise SystemExit("phase C needs phase A's state and the WAL copy")
    out = {"C_begin": now(), "C_wal_bytes": os.path.getsize(os.path.join(rc, "dagdb.wal"))}
    c = Daemon(args.bin, rc, args.side).start(pre_wait=args.pre_wait, label="r8 C (WAL replay)")
    out["C_mem_at_start_gib"] = round(c.mem_at_start / GIB, 1) if c.mem_at_start else None
    out["C_startup_with_replay_s"] = round(c.startup_s, 2)
    try:
        log = open(os.path.join(rc, "daemon.log")).read()
        out["C_replay_lines"] = [l.strip() for l in log.splitlines() if "WAL:" in l]
        out["C_rss_after_replay_mb"] = round(c.rss_mb())
        hC0, perC0, _, _, _ = export_hash(c, "C0")
    finally:
        c.stop()
    out["C_memory"] = c.mem
    for f in ("dagdb.wal", "dagdb_shm"):
        p = os.path.join(rc, f)
        if os.path.exists(p):
            os.remove(p)
    out.update(hash_C0=hC0, files_C0=perC0, C_end=now())
    r8_state(stp, out)


def r8_verdict(args):
    base, ra, rb, rc, stp = r8_paths(args)
    st = r8_state(stp)
    for r_ in (ra, rb, rc):
        for f in ("dagdb.wal", "dagdb_shm"):
            p = os.path.join(r_, f)
            if os.path.exists(p):
                os.remove(p)
    v = {}
    h = st["header"]
    v["v8_header"] = h["magic"] == "DAGS" and h["version"] == 8 and h["bodyBytes28"] == 0xFFFFFFFF and h["nodes"] == st["nodes"]
    v["body_len"] = h["body_len"]
    v["body_exceeds_4GiB"] = h["body_len"] > 4 * GIB
    v["load_then_10_ticks_equal"] = st["hash_B10"] == st["hash_A10"]
    v["load_equal_before_ticks"] = st["hash_B0"] == st["hash_A0"]
    v["ticks_moved_truth"] = st["truth_bytes_changed_by_10_ticks"] > 0
    v["gate_a"] = v["v8_header"] and v["body_exceeds_4GiB"] and v["load_then_10_ticks_equal"]
    rl = " ".join(st["C_replay_lines"])
    v["replay_skipped0"] = "skipped=0" in rl and "WAL: skipped" not in rl and "replay failed" not in rl
    v["wal_replay_equal"] = st["hash_C0"] == st["hash_A0"]
    v["gate_b"] = v["wal_replay_equal"]
    if not v["load_then_10_ticks_equal"]:
        v["differing_files_after_10"] = [k for k in st["files_A10"] if st["files_A10"][k] != st["files_B10"].get(k)]
    if not v["wal_replay_equal"]:
        v["differing_files_replay"] = [k for k in st["files_A0"] if st["files_A0"][k] != st["files_C0"].get(k)]
    st = r8_state(stp, {"verdict": v})
    short = {k: st[k] for k in st if not k.startswith("files_")}
    print("R8RESULT " + json.dumps(short), flush=True)
    if args.out:
        with open(args.out, "a") as fh:
            fh.write(json.dumps(dict(when=now(), **short)) + "\n")


def r8(args):
    phases = {"A": r8_phase_a, "B": r8_phase_b, "C": r8_phase_c, "verdict": r8_verdict}
    for p in (["A", "B", "C", "verdict"] if args.phase == "all" else [args.phase]):
        print(f"[{now()}] r8 side={args.side} phase {p}", flush=True)
        phases[p](args)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="sub", required=True)
    p = sub.add_parser("perf")
    p.add_argument("--bin", required=True)
    p.add_argument("--root", required=True)
    p.add_argument("--side", type=int, required=True)
    p.add_argument("--kind", default="binary", choices=["binary", "mixed", "ternary"])
    p.add_argument("--seed", type=int, default=0x7E128)
    p.add_argument("--label", default="run")
    p.add_argument("--out")
    p.add_argument("--pre-wait", type=int, default=0)
    p.add_argument("--quiet-wait", type=int, default=0,
                   help="minutes to wait for an idle GPU (<= 10%% in 10 one-second samples) before starting; 0 = no rule")
    q = sub.add_parser("r8")
    q.add_argument("--bin", required=True)
    q.add_argument("--root", required=True)
    q.add_argument("--side", type=int, required=True)
    q.add_argument("--seed", type=int, default=0x7E128)
    q.add_argument("--phase", default="all", choices=["all", "A", "B", "C", "verdict"])
    q.add_argument("--out")
    q.add_argument("--pre-wait", type=int, default=0)
    b = sub.add_parser("ab")
    b.add_argument("--main", required=True, help="the reference daemon (main's release binary)")
    b.add_argument("--build", required=True, help="the daemon under test")
    b.add_argument("--root", required=True)
    b.add_argument("--side", type=int, required=True)
    b.add_argument("--pairs", type=int, default=AB_PAIRS)
    b.add_argument("--seed", type=int, default=0x7E128)
    b.add_argument("--label", default="run")
    b.add_argument("--out")
    a = ap.parse_args()
    if a.sub == "perf":
        perf(a)
    elif a.sub == "r8":
        r8(a)
    elif a.sub == "ab":
        if a.pairs < 5:
            raise SystemExit("R8(d) needs at least 5 pairs")
        ab(a)


if __name__ == "__main__":
    main()
